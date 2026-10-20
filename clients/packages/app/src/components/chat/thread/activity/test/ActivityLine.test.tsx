import { CommaI18nProvider } from "@comma/i18n/react";
import { initializeCommaI18n } from "@comma/i18n";
import { render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act } from "react";
import { ParticipantStatusSlot } from "../ActivityLine";
import type { ActivityFocus, ActivityFocusTask } from "../activityFocus";
import type { ChatActivity, ChatParticipantStatus } from "@comma/core/chat";

beforeEach(() => {
  initializeCommaI18n(["en"]);
});
afterEach(() => {
  initializeCommaI18n(["en"]);
});

const router: ChatParticipantStatus = {
  conversationId: "task_1",
  participantId: "router",
  actorId: "actor_router",
  actorRole: "router",
  name: "Default workspace Router",
  state: "active",
  status: "is thinking...",
  updatedAt: 1,
};
const worker: ChatParticipantStatus = {
  ...router,
  participantId: "worker_1",
  actorId: "actor_worker_1",
  actorRole: "worker",
  name: "Default workspace Worker",
};
const designer = {
  ...worker,
  participantId: "worker_2",
  actorId: "actor_worker_2",
  name: "Designer",
};
const reviewer = {
  ...worker,
  participantId: "worker_3",
  actorId: "actor_worker_3",
  name: "Reviewer",
};

function statusView(
  participants: ChatParticipantStatus[],
  locale: "en" | "zh-CN" = "en",
  workerVendor?: string
) {
  return (
    <CommaI18nProvider locale={locale}>
      <ParticipantStatusSlot
        participantStatus={undefined}
        participantStatuses={participants}
        workerVendor={workerVendor}
      />
    </CommaI18nProvider>
  );
}

function zhErrorView(issue: string, status: string) {
  return render(
    <CommaI18nProvider locale="zh-CN">
      <ParticipantStatusSlot
        participantStatus={{
          conversationId: "cnv_1",
          issue,
          participantId: "ptp_1",
          state: "error",
          status,
          updatedAt: 1_780_000_000_700,
        }}
      />
    </CommaI18nProvider>
  );
}

describe("Task activity summary", () => {
  it("animates only the active Router avatar, and shows the Worker by its model's maker", () => {
    const view = render(statusView([router, worker], "en", "anthropic"));
    const routerAvatar = view.container.querySelector('[data-actor-role="router"]');
    const workerAvatar = view.container.querySelector('[data-actor-role="worker"]');
    const logo = routerAvatar?.querySelector('[data-slot="comma-logo-animation"]');
    expect(logo).toBeInTheDocument();
    // Real 16px sizing is asserted with the application CSS in Playwright.
    expect(routerAvatar).toHaveClass("comma-chat-assistant-router-mark");
    expect(logo).toHaveAttribute("data-paused", "false");
    expect(workerAvatar).toHaveAttribute("data-model-vendor", "anthropic");
    expect(workerAvatar?.querySelector("img")).toBeInTheDocument();

    view.rerender(statusView([{ ...router, updatedAt: 2 }, worker], "en", "anthropic"));
    expect(view.container.querySelector('[data-slot="comma-logo-animation"]')).toBe(
      logo
    );

    view.rerender(
      statusView([{ ...router, state: "error", status: "Runtime unavailable" }])
    );
    expect(
      view.container.querySelector('[data-slot="comma-logo-animation"]')
    ).toBeNull();
    expect(view.container.querySelector(".comma-chat-activity-avatars")).toBeNull();
    expect(view.container.querySelector(".comma-chat-activity-avatar")).toBeNull();

    view.rerender(statusView([{ ...router, state: "stopped", status: "" }]));
    expect(view.container.querySelector(".comma-chat-activity-avatar")).toBeNull();
  });

  it.each([
    [[router], "Router is thinking"],
    [[worker], "Worker is thinking"],
    [[worker, router], "Router and Worker are thinking"],
    [[worker, designer], "Worker and Designer are thinking"],
    [[router, worker, designer], "Router and 2 workers are thinking"],
    [[worker, designer, reviewer], "3 workers are thinking"],
  ] as const)("groups active names in one line: %s", (participants, label) => {
    render(statusView([...participants]));
    expect(screen.getByRole("status")).toHaveTextContent(label);
    expect(screen.getAllByRole("status")).toHaveLength(1);
    expect(screen.getByTestId("participant-status-slot")).not.toHaveTextContent(
      "Default workspace"
    );
  });

  it.each([
    [[worker], "Worker 正在思考"],
    [[worker, router], "Router 和 Worker 正在思考"],
    [[router, worker, designer], "Router 和 2 个 Worker 正在思考"],
    [[worker, designer, reviewer], "3 个 Worker 正在思考"],
  ] as const)("localizes the complete thinking status: %s", (participants, label) => {
    render(statusView([...participants], "zh-CN"));
    expect(screen.getByRole("status")).toHaveTextContent(label);
  });

  it("keeps the activity and avatar mounted when only the status timestamp/text changes", () => {
    const view = render(statusView([worker]));
    const avatar = view.container.querySelector(".comma-chat-activity-avatar");
    const activity = view.container.querySelector('[data-slot="ai-activity"]');
    const text = screen.getByText("Worker is thinking");

    view.rerender(
      statusView([{ ...worker, status: "is executing a tool...", updatedAt: 2 }])
    );
    expect(view.container.querySelector(".comma-chat-activity-avatar")).toBe(avatar);
    expect(view.container.querySelector('[data-slot="ai-activity"]')).toBe(activity);
    expect(screen.getByText("Worker is thinking")).toBe(text);
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "title",
      "Worker · Working"
    );
  });

  it("does not count stopped or failed workers as active, and keeps errors available", () => {
    const view = render(
      statusView([
        router,
        { ...worker, state: "stopped", status: "" },
        {
          ...designer,
          issue: "runtime_failed",
          state: "error",
          status: "error: runtime failed",
        },
      ])
    );
    expect(screen.getByRole("alert")).toHaveTextContent("Router");
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "title",
      expect.stringContaining(
        "Designer · Stopped because of an error. Try sending again."
      )
    );
    view.rerender(statusView([]));
    expect(screen.queryByRole("status")).toBeNull();
    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "data-active",
      "false"
    );
  });
});

const ownerSlotView = (
  participantStatus: ChatParticipantStatus | undefined,
  streaming = false
) => (
  <CommaI18nProvider locale="en">
    <ParticipantStatusSlot
      hasResponse
      participantStatus={participantStatus}
      streaming={streaming}
    />
  </CommaI18nProvider>
);

describe("ParticipantStatusSlot", () => {
  it("clears the channel when work stops and preserves localized channel copy", () => {
    const view = render(
      <CommaI18nProvider locale="zh-CN">
        <ParticipantStatusSlot
          participantStatus={{ ...router, workingProvider: "wechat" }}
        />
      </CommaI18nProvider>
    );
    expect(screen.getByRole("status")).toHaveTextContent("Comma 正在微信上处理消息");
    view.rerender(
      <ParticipantStatusSlot
        participantStatus={{ ...router, state: "stopped", status: "" }}
      />
    );
    return vi.waitFor(() =>
      expect(screen.queryByRole("status")).not.toBeInTheDocument()
    );
  });

  it("holds brief empty snapshots without remounting the thinking avatar", () => {
    const view = render(statusView([router]));
    const slot = screen.getByTestId("participant-status-slot");
    const avatar = view.container.querySelector(".comma-chat-activity-avatar");
    view.rerender(statusView([]));
    act(() => vi.advanceTimersByTime(100));
    expect(slot).toHaveAttribute("data-active", "true");
    view.rerender(statusView([router]));
    expect(view.container.querySelector(".comma-chat-activity-avatar")).toBe(avatar);
    act(() => vi.advanceTimersByTime(200));
    expect(slot).toHaveAttribute("data-active", "true");
    view.rerender(statusView([]));
    act(() => vi.advanceTimersByTime(180));
    expect(slot).toHaveAttribute("data-active", "false");
    view.unmount();
  });
  it("keeps owner-backed work after a reply without exposing private status", async () => {
    const status = { ...router, status: "is waiting: private implementation detail" };
    const view = render(ownerSlotView(status));
    const slot = screen.getByTestId("participant-status-slot");
    expect(slot).toHaveAttribute("data-active", "true");
    expect(currentSummary(view.container)).toHaveTextContent("Working");
    expect(slot).not.toHaveTextContent("private implementation detail");
    view.rerender(ownerSlotView({ ...status, state: "stopped" }));
    expect(slot).toHaveAttribute("data-active", "false");
    view.rerender(ownerSlotView(status, true));
    expect(slot).toHaveAttribute("data-active", "false");
    view.rerender(ownerSlotView({ ...status, state: "stopped" }));
    expect(slot).toHaveAttribute("data-active", "false");
    view.rerender(ownerSlotView(undefined));
    expect(slot).toHaveAttribute("data-active", "false");
    view.rerender(
      ownerSlotView({
        ...status,
        issue: "runtime_observation_lost",
        state: "error",
        status: "error: runtime observation was lost",
      })
    );
    const lost =
      "Lost connection to the computer while working. Check that it’s online.";
    await screen.findByText(lost);
    expect(screen.getByRole("alert")).toHaveTextContent(lost);
    expect(slot).not.toHaveTextContent("runtime observation");
    expect(view.container.querySelector(".comma-chat-activity-avatar")).toBeNull();
  });

  it("keeps a background Loop wake out of the previous chat reply", () => {
    const view = render(
      <ParticipantStatusSlot hasResponse participantStatus={router} />
    );
    const slot = screen.getByTestId("participant-status-slot");
    expect(slot).toHaveAttribute("data-active", "true");

    view.rerender(
      <ParticipantStatusSlot
        hasResponse
        participantStatus={{ ...router, loopWake: true }}
      />
    );
    expect(slot).toHaveAttribute("data-active", "false");

    view.rerender(
      <ParticipantStatusSlot
        hasResponse
        participantStatus={{ ...router, loopWake: true }}
        streaming
      />
    );
    expect(slot).toHaveAttribute("data-active", "false");
  });

  describe("Task work", () => {
    // The Home round that waited for the Worker left its tool frame behind.
    const waitFrame: ChatActivity = {
      phase: "execution",
      status: "running",
      summaryClass: "public",
      toolName: "wait_for",
    };
    const codex = {
      active: true,
      avatarId: "actor_codex",
      name: "Codex Worker",
      participantId: "ptp_codex",
      vendor: "openai",
    };
    const weekly: ActivityFocusTask = {
      conversationId: "task_weekly",
      statusBucket: "in_progress",
      title: "整理本周周报",
      worker: codex,
    };
    const billing: ActivityFocusTask = {
      conversationId: "task_billing",
      statusBucket: "in_progress",
      title: "核对 Q3 账单",
      worker: {
        ...codex,
        avatarId: "actor_claude",
        name: "Claude Worker",
        vendor: "anthropic",
      },
    };
    it.each(["en", "zh-CN"] as const)(
      "names the Task and Worker that the Router follows up on (%s)",
      async (locale) => {
        const following = {
          ...router,
          workingConversationIds: [weekly.conversationId],
        };
        const view = render(
          slotView(
            {
              activity: waitFrame,
              participantStatus: following,
              focus: focusOf("following", [weekly]),
            },
            locale
          )
        );
        // The earlier round's tool frame is stale: it never shows.
        expect(currentSummary(view.container)).toHaveTextContent(
          locale === "en"
            ? "Reviewing an update on “整理本周周报”"
            : "正在处理「整理本周周报」的新进展"
        );
        const bubble = bubbleOf(view.container);
        expect(bubble.querySelector(".comma-chat-thinking-logo")).not.toBeNull();
        // The Worker shows as the mark of its model's maker.
        expect(bubble.querySelectorAll("[data-worker-avatar]")).toHaveLength(1);
        expect(bubble.querySelector("[data-worker-avatar]")).toHaveAttribute(
          "data-model-vendor",
          "openai"
        );

        // Until this reader resolves the Task, the line stays generic.
        view.rerender(
          slotView(
            {
              activity: waitFrame,
              participantStatus: following,
              focus: focusOf("following", [{ conversationId: weekly.conversationId }]),
            },
            locale
          )
        );
        await vi.waitFor(() =>
          expect(currentSummary(view.container)).toHaveTextContent(
            locale === "en" ? "Thinking" : "思考中"
          )
        );
      }
    );

    it("words the whole wait, also after its tool frame expires", async () => {
      const waiting = {
        ...router,
        waiting: true,
        status: "is waiting: private reason",
      };
      const view = render(slotView({ participantStatus: waiting }));
      expect(currentSummary(view.container)).toHaveTextContent("正在等进展");
      expect(view.container).not.toHaveTextContent("private reason");

      view.rerender(slotView({ participantStatus: waiting, hasResponse: true }));
      await vi.waitFor(() =>
        expect(currentSummary(view.container)).toHaveTextContent("正在等进展")
      );

      view.rerender(
        slotView({
          participantStatus: waiting,
          hasResponse: true,
          focus: focusOf("waiting", [weekly]),
        })
      );
      await vi.waitFor(() =>
        expect(currentSummary(view.container)).toHaveTextContent(
          "正在等「整理本周周报」完成"
        )
      );
    });

    it("counts several Tasks and shows at most two Worker avatars", () => {
      const third = {
        ...billing,
        conversationId: "task_third",
        worker: { ...codex, avatarId: "actor_third" },
      };
      const view = render(
        slotView({
          participantStatus: {
            ...router,
            workingConversationIds: ["task_weekly", "task_billing", "task_third"],
          },
          focus: focusOf("following", [weekly, billing, third]),
        })
      );
      expect(currentSummary(view.container)).toHaveTextContent(
        "正在处理 3 个任务的新进展"
      );
      expect(
        bubbleOf(view.container).querySelectorAll("[data-worker-avatar]")
      ).toHaveLength(2);
    });

    it("shows Workers that work while the Router is idle, never over an error", async () => {
      const view = render(
        slotView({
          participantStatus: { ...router, state: "stopped", status: "" },
          focus: focusOf("working", [weekly]),
          hasResponse: true,
        })
      );
      const slot = screen.getByTestId("participant-status-slot");
      expect(slot).toHaveAttribute("data-active", "true");
      expect(currentSummary(view.container)).toHaveTextContent(
        "「整理本周周报」进行中"
      );
      const bubble = bubbleOf(view.container);
      expect(bubble.querySelector(".comma-chat-thinking-logo")).toBeNull();
      expect(bubble.querySelectorAll("[data-worker-avatar]")).toHaveLength(1);

      view.rerender(
        slotView({
          participantStatus: {
            ...router,
            state: "error",
            status: "error: runtime failed",
            issue: "runtime_failed",
          },
          focus: focusOf("working", [weekly]),
          hasResponse: true,
        })
      );
      // The line swaps to the error notice; the outgoing text then leaves.
      await vi.waitFor(() => expect(slot).not.toHaveTextContent("进行中"));
    });

    it("is the link to the Task its line names, with a card whose rows open each Task", async () => {
      const opened = vi.fn();
      // A Task link rendered as a button.
      const taskLink = (task: ActivityFocusTask) => (
        <button
          type="button"
          aria-label={`打开任务：${task.title}`}
          onClick={() => opened(task.conversationId)}
        />
      );
      const user = userEvent.setup();
      setInteractionModality("pointer");
      render(
        slotView({
          participantStatus: {
            ...router,
            workingConversationIds: [weekly.conversationId, billing.conversationId],
          },
          focus: focusOf("following", [weekly, billing]),
          taskLink,
        })
      );
      const bubble = screen.getByRole("button", {
        name: "正在处理 2 个任务的新进展",
      });
      await user.hover(bubble);
      const card = await screen.findByRole(
        "dialog",
        { name: "2 个任务" },
        { timeout: 3_000 }
      );
      // A row names the Worker and the Task, and holds the status until a step loads.
      const row = within(card).getByRole("button", { name: "打开任务：核对 Q3 账单" });
      expect(row).toHaveTextContent("Claude Worker");
      expect(row).toHaveTextContent("核对 Q3 账单");
      expect(row).toHaveTextContent("进行中");
      await user.hover(row);
      await user.click(row);
      expect(opened).toHaveBeenCalledExactlyOnceWith(billing.conversationId);

      // The bubble itself opens the Task that its line names.
      opened.mockClear();
      await user.click(bubble);
      expect(opened).toHaveBeenCalledExactlyOnceWith(weekly.conversationId);
    });

    it("lists only Tasks the reader can see and never fills a row with stand-in words", async () => {
      const user = userEvent.setup();
      setInteractionModality("pointer");
      // Its feed has not answered yet, and its status is still loading.
      const loading: ActivityFocusTask = {
        ...billing,
        worker: undefined,
        statusBucket: undefined,
      };
      // Its feed answered: no Worker is bound yet.
      const queued: ActivityFocusTask = {
        ...weekly,
        conversationId: "task_queued",
        title: "排队中的任务",
        worker: null,
      };
      render(
        slotView({
          participantStatus: {
            ...router,
            workingConversationIds: ["task_unseen", "task_billing", "task_queued"],
          },
          focus: focusOf("following", [
            { conversationId: "task_unseen" },
            loading,
            queued,
          ]),
          taskLink: inertTaskLink,
        })
      );
      // The Task without a title is neither counted in the bubble nor listed.
      const bubble = screen.getByRole("button", { name: "正在处理 2 个任务的新进展" });
      await user.hover(bubble);
      const card = await screen.findByRole(
        "dialog",
        { name: "2 个任务" },
        { timeout: 3_000 }
      );
      expect(within(card).getAllByRole("button")).toHaveLength(2);
      expect(
        within(card).getByRole("button", { name: "打开任务：核对 Q3 账单" })
      ).not.toHaveTextContent("Worker");
      expect(
        within(card).getByRole("button", { name: "打开任务：排队中的任务" })
      ).toHaveTextContent("还没有 Worker");
    });
  });

  it("does not promote private tool copy and preserves public execution errors", () => {
    const activity = {
      phase: "execution",
      status: "running",
      summaryClass: "none" as const,
      summary: "Internal implementation detail",
      toolName: "calendar.list_items",
    };
    const view = render(
      <ParticipantStatusSlot
        activity={activity}
        hasResponse
        participantStatus={router}
      />
    );
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "data-active",
      "true"
    );
    expect(currentSummary(view.container)).toHaveTextContent("Working");
    expect(view.container).not.toHaveTextContent("calendar.list_items");
    expect(view.container).not.toHaveTextContent("Internal implementation detail");
    view.rerender(
      <ParticipantStatusSlot
        activity={{
          ...activity,
          status: "failed",
          summaryClass: "public",
          summary: "Calendar unavailable",
        }}
        hasResponse
        participantStatus={router}
      />
    );
    expect(screen.getByRole("alert")).toHaveTextContent("Couldn’t check your calendar");
  });

  it("keeps a silent acknowledged wait visible without inventing a runtime failure", async () => {
    const view = render(
      <ParticipantStatusSlot participantStatus={undefined} replyTimedOut />
    );
    expect(
      screen.getByText("Message sent. No reply received yet.")
    ).toBeInTheDocument();
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "data-state",
      "waiting"
    );
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "data-active",
      "true"
    );
    expect(view.container.querySelector('[data-slot="ai-activity"]')).toHaveAttribute(
      "aria-busy",
      "false"
    );
    expect(currentSummary(view.container)).toHaveAttribute("data-shimmer", "false");
    expect(screen.queryByRole("alert")).toBeNull();
    expect(view.container.querySelector(".comma-chat-activity-avatar")).toBeNull();

    // The local deadline cannot mask resumed streaming or a later failure.
    view.rerender(
      <ParticipantStatusSlot participantStatus={undefined} replyTimedOut streaming />
    );
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "data-state",
      "active"
    );
    expect(currentSummary(view.container)).toHaveTextContent("Typing");
    view.rerender(
      <ParticipantStatusSlot
        participantStatus={{
          conversationId: "cnv_1",
          participantId: "ptp_1",
          state: "error",
          status: "Public runtime error",
          updatedAt: 100,
        }}
        replyTimedOut
      />
    );
    const generic = "Something went wrong. Try sending again.";
    expect(await screen.findByText(generic)).toBeInTheDocument();
    expect(screen.getByRole("alert")).toHaveTextContent(generic);
    expect(screen.queryByText("Public runtime error")).toBeNull();
  });

  it("shows optimistic thinking and yields to real participant activity", () => {
    const view = render(
      <ParticipantStatusSlot participantStatus={undefined} optimisticThinking />
    );

    const slot = screen.getByTestId("participant-status-slot");
    expect(slot).toHaveAttribute("data-active", "true");
    expect(screen.getByText("Thinking")).toBeInTheDocument();
    expect(currentSummary(view.container)).toHaveAttribute("data-shimmer", "true");
    expect(
      view.container.querySelector(".comma-chat-thinking-logo")
    ).toBeInTheDocument();

    view.rerender(
      <ParticipantStatusSlot
        activity={{
          phase: "execution",
          status: "running",
          summaryClass: "public",
          summary: "Working",
          toolName: "calendar.list_items",
        }}
        participantStatus={{
          conversationId: "cnv_1",
          participantId: "ptp_1",
          state: "active",
          status: "is executing a tool...",
          updatedAt: 1_780_000_000_100,
        }}
      />
    );

    expect(screen.getByText("Checking your calendar")).toBeInTheDocument();
    expect(slot).toHaveAttribute("title", "Checking your calendar");
  });

  it("keeps current local send feedback despite the previous stopped snapshot", () => {
    render(
      <ParticipantStatusSlot
        optimisticThinking
        participantStatus={{
          conversationId: "cnv_1",
          participantId: "ptp_1",
          state: "stopped",
          status: "",
          updatedAt: 1_780_000_000_100,
        }}
      />
    );

    expect(screen.getByText("Thinking")).toBeInTheDocument();
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "data-active",
      "true"
    );
  });

  it("keeps an inaccessible empty row when no exact Participant status is available", () => {
    const { container } = render(
      <ParticipantStatusSlot participantStatus={undefined} />
    );

    const slot = screen.getByTestId("participant-status-slot");
    expect(slot).toHaveAttribute("data-active", "false");
    expect(slot.firstElementChild).toHaveAttribute("aria-hidden", "true");
    expect(container.querySelector('[data-slot="ai-activity"]')).toBeInTheDocument();
    expect(screen.queryByRole("status")).toBeNull();
  });

  it("uses localized active copy, words errors from their issue and hides stopped", () => {
    const view = render(
      <ParticipantStatusSlot
        participantStatus={{
          conversationId: "cnv_1",
          participantId: "ptp_1",
          state: "active",
          status: "is executing a tool...",
          updatedAt: 1_780_000_000_100,
        }}
      />
    );

    expect(screen.getByText("Thinking")).toBeInTheDocument();
    expect(screen.queryByText("is executing a tool...")).toBeNull();
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "data-active",
      "true"
    );
    expect(currentSummary(view.container)).toHaveAttribute("data-shimmer", "true");

    view.rerender(
      <ParticipantStatusSlot
        participantStatus={{
          conversationId: "cnv_1",
          participantId: "ptp_1",
          issue: "rate_limited",
          state: "error",
          status: "error: model request failed.",
          updatedAt: 1_780_000_000_200,
        }}
      />
    );
    expect(
      screen.getByText("Too many requests right now. Try again in a moment.")
    ).toBeInTheDocument();
    expect(screen.queryByText("error: model request failed.")).toBeNull();
    expect(view.container.querySelector('[data-slot="ai-activity"]')).toHaveAttribute(
      "data-status",
      "failed"
    );
    expect(view.container.querySelector(".comma-chat-activity-avatars")).toBeNull();
    expect(view.container.querySelector(".comma-chat-activity-avatar")).toBeNull();

    view.rerender(
      <ParticipantStatusSlot
        participantStatus={{
          conversationId: "cnv_1",
          participantId: "ptp_1",
          state: "stopped",
          status: "",
          updatedAt: 1_780_000_000_300,
        }}
      />
    );
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "data-active",
      "false"
    );
  });

  // A source-bound failure frame has no stable runtime issue. Keep it visible
  // while the durable Participant snapshot is still stopped, but do not infer
  // a model-specific cause from the presentation lifecycle alone.
  it("surfaces a generic failed turn while the Participant status reads stopped", () => {
    const view = render(
      <ParticipantStatusSlot
        activity={{
          phase: "thinking",
          responseKey: "rsp_1",
          sequence: 7,
          status: "failed",
          summaryClass: "generic",
        }}
        participantStatus={{
          conversationId: "cnv_1",
          participantId: "ptp_1",
          state: "stopped",
          status: "",
          updatedAt: 1_780_000_000_400,
        }}
      />
    );

    expect(screen.getByText("Generation failed")).toBeInTheDocument();
    expect(
      screen.queryByText(
        "The model request failed, so work stopped. If this keeps happening, choose another model."
      )
    ).not.toBeInTheDocument();
    const slot = screen.getByTestId("participant-status-slot");
    expect(slot).toHaveAttribute("data-active", "true");
    expect(slot).toHaveAttribute("data-state", "error");
    expect(view.container.querySelector('[data-slot="ai-activity"]')).toHaveAttribute(
      "data-status",
      "failed"
    );
    expect(view.container.querySelector(".comma-chat-activity-avatars")).toBeNull();
  });

  it("keeps a public tool failure distinct from a model connection failure", () => {
    render(
      <ParticipantStatusSlot
        activity={{
          phase: "execution",
          responseKey: "rsp_tool",
          sequence: 8,
          status: "failed",
          summary: "Running a command",
          summaryClass: "public",
          toolName: "env.exec",
        }}
        participantStatus={{
          conversationId: "cnv_1",
          participantId: "ptp_1",
          state: "stopped",
          status: "",
          updatedAt: 1_780_000_000_450,
        }}
      />
    );

    expect(screen.getByText("The command failed")).toBeInTheDocument();
    expect(
      screen.queryByText(
        "The model request failed, so work stopped. If this keeps happening, choose another model."
      )
    ).not.toBeInTheDocument();
  });

  it("words a tool call after a reply in the reader's language, never as its identifier", () => {
    const slotView = (activity: ChatActivity) => (
      <CommaI18nProvider locale="zh-CN">
        <ParticipantStatusSlot
          activity={activity}
          hasResponse
          participantStatus={router}
        />
      </CommaI18nProvider>
    );
    const execution = {
      phase: "execution",
      status: "running",
      summaryClass: "public" as const,
    };
    // Earlier producers put the raw identifier into their English summary.
    const task = render(
      slotView({
        ...execution,
        summary: "Running im_api.internal.update_conversation",
        toolName: "im_api.internal.update_conversation",
      })
    );
    expect(currentSummary(task.container)).toHaveTextContent("正在更新任务");
    expect(task.container).not.toHaveTextContent("im_api");
    expect(task.container).not.toHaveTextContent("Running");
    task.unmount();

    // The model's own label for its command is the most specific wording.
    const command = render(
      slotView({
        ...execution,
        goal: "正在检查日志",
        summary: "正在检查日志",
        toolName: "env.exec",
      })
    );
    expect(currentSummary(command.container)).toHaveTextContent("正在检查日志");
    command.unmount();

    // A messaging app's operation names the app and whether it sends.
    const send = render(
      slotView({
        ...execution,
        summary: "Working",
        toolName: "im_api.feishu.send_text",
      })
    );
    expect(currentSummary(send.container)).toHaveTextContent("正在发送飞书消息");
    send.unmount();
    const larkSend = render(
      slotView({
        ...execution,
        summary: "Working",
        toolName: "im_api.lark.send_message",
      })
    );
    expect(currentSummary(larkSend.container)).toHaveTextContent("正在发送 Lark 消息");
    larkSend.unmount();
    const read = render(
      slotView({
        ...execution,
        summary: "Working",
        toolName: "im_api.slack.get_channel_history",
      })
    );
    expect(currentSummary(read.container)).toHaveTextContent("正在使用 Slack");
    read.unmount();

    const unworded = render(
      slotView({ ...execution, summary: "Working", toolName: "help" })
    );
    expect(currentSummary(unworded.container)).toHaveTextContent("正在处理");
    expect(unworded.container).not.toHaveTextContent("help");
    unworded.unmount();

    // Activity precedes dispatch, so a model-invented name reaches the client.
    const invented = render(
      slotView({ ...execution, summary: "Working", toolName: "toString" })
    );
    expect(currentSummary(invented.container)).toHaveTextContent("正在处理");
  });

  // The durable half: the in-memory failure frame dies with an SSE reconnect
  // (the agent's activity surface drops the session on the terminal idle), so
  // the runtime also settles the session's own activity to error with a stable
  // reason code. That one survives a reload, and carries localized copy rather
  // than the runtime's English text.
  it("says when a model request failed and what started its round", () => {
    // The line stays under the newest message, so it names the failure time
    // and a background or voice call start instead of reading as that reply.
    for (const [trigger, copy] of [
      [undefined, "这次模型请求失败，已停止处理。如果反复出现，请换一个模型。"],
      [
        "background",
        "后台任务的模型请求失败，已停止处理。如果反复出现，请换一个模型。",
      ],
      [
        "voice_call",
        "语音通话中的模型请求失败，已停止处理。如果反复出现，请换一个模型。",
      ],
    ] as const) {
      const view = render(
        <CommaI18nProvider locale="zh-CN">
          <ParticipantStatusSlot
            participantStatus={{
              conversationId: "cnv_1",
              issue: "model_connection_failed",
              ...(trigger ? { issueDetail: { trigger } } : {}),
              participantId: "ptp_1",
              state: "error",
              status: "error: the model request failed",
              updatedAt: 1_791_244_815,
            }}
          />
        </CommaI18nProvider>
      );
      const alert = view.getByRole("alert");
      expect(alert).toHaveTextContent(new RegExp(`\\d{1,2}:\\d{2} · ${copy}$`));
      expect(alert).not.toHaveTextContent("the model request failed");
      view.unmount();
    }
  });

  it("words runtime issues in the reader's language, never the runtime's text", () => {
    const parked = zhErrorView("runaway_guard_parked", "error: runaway guard parked");
    expect(parked.getByRole("alert")).toHaveTextContent(
      "一直没有进展，已自动停止。请换个说法再试。"
    );
    expect(parked.container).not.toHaveTextContent("runaway");
    parked.unmount();

    // An external runtime's own message stays out of the chat; the Router
    // relays provider details such as a reset time in its reply.
    const limited = zhErrorView(
      "quota_exhausted",
      "error: You've hit your usage limit. Resets at 5pm."
    );
    expect(limited.getByRole("alert")).toHaveTextContent(
      "已达到用量上限，请在额度恢复后再试。"
    );
    expect(limited.container).not.toHaveTextContent("usage limit");
    limited.unmount();

    const unknown = zhErrorView("future_issue", "error: future issue");
    expect(unknown.getByRole("alert")).toHaveTextContent("出了点问题，请重新发送。");
    expect(unknown.container).not.toHaveTextContent("future");
  });

  it("words each Task Participant from its state and issue, never its runtime text", () => {
    render(
      statusView(
        [
          { ...router, status: "is executing a tool..." },
          {
            ...worker,
            issue: "authentication_required",
            state: "error",
            status: "error: Codex needs `codex login` on host-7",
          },
        ],
        "zh-CN"
      )
    );
    const slot = screen.getByTestId("participant-status-slot");
    expect(slot).toHaveAttribute(
      "title",
      "Router · 正在处理\nWorker · 需要重新登录才能继续。"
    );
    expect(slot.getAttribute("title")).not.toContain("executing");
    expect(slot).not.toHaveTextContent("codex");
  });

  it("shows Comma Center router thinking with generic copy and the animated mark", () => {
    const view = render(
      <ParticipantStatusSlot
        activity={{ phase: "thinking", status: "running" }}
        participantStatus={{
          conversationId: "cnv_1",
          participantId: "ptp_1",
          state: "active",
          status: "is thinking...",
          updatedAt: 1_780_000_000_500,
        }}
      />
    );

    expect(screen.getByText("Thinking")).toBeInTheDocument();
    expect(screen.queryByText("is thinking...")).not.toBeInTheDocument();
    expect(
      view.container.querySelector('[data-slot="comma-logo-animation"]')
    ).toBeInTheDocument();
    expect(
      view.container.querySelector(
        '.comma-chat-thinking-bubble [data-slot="comma-logo-animation"]'
      )
    ).toBeInTheDocument();
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "data-state",
      "active"
    );
  });
});

const focusOf = (
  mode: ActivityFocus["mode"],
  tasks: ActivityFocusTask[]
): ActivityFocus => ({ groupId: "group", mode, tasks });
const slotView = (
  props: Partial<Parameters<typeof ParticipantStatusSlot>[0]>,
  locale: "en" | "zh-CN" = "zh-CN"
) => (
  <CommaI18nProvider locale={locale}>
    <ParticipantStatusSlot participantStatus={undefined} {...props} />
  </CommaI18nProvider>
);
// A surface link that only names its Task.
const inertTaskLink = (task: ActivityFocusTask) => (
  <button type="button" aria-label={`打开任务：${task.title}`} />
);
const bubbleOf = (container: HTMLElement) =>
  container.querySelector<HTMLElement>(".comma-chat-thinking-bubble")!;

function currentSummary(container: HTMLElement) {
  return container.querySelector(
    '.comma-ai-activity-text-layer:not([aria-hidden="true"]) .comma-ai-activity-text-summary'
  );
}
