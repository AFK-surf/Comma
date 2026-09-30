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
import { CommaI18nProvider } from "@comma/i18n/react";
import { Toaster, toast } from "@comma/ui";
import { useMemo, useState, type ComponentProps, type ReactElement } from "react";
import { setInteractionModality } from "react-aria/private/interactions/useFocusVisible";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CommaApiClient, CommaSkill } from "../../../../api";
import { Composer } from "../../composer/Composer";
import type { ComposerMentionSources } from "../../composer/useComposerMentionSources";
import {
  ConversationThread,
  type ChatOutgoingLaunch,
} from "../../thread/ConversationThread";
import { CONVERSATION_TURN_WINDOW } from "../../thread/navigation/conversationTurnWindow";
import { ConversationView, type ConversationViewActions } from "../ConversationView";
import { fixedDraftSource } from "../../composer/conversationDraft";
import { LocalFilePreviewCache } from "../../../../runtime-chat/channel/preview/LocalFilePreviewCache";
import type {
  AttachmentUploadInput,
  ChatImagePreviewRef,
  ChatMessage,
  ConversationChannelState,
  PendingSend,
} from "../../model/conversationChannel";
import { composeMessageWithAttachments } from "../../model/protocol";
import {
  initialResponseOwnerTurnKey,
  visibleReplyIdentityKey,
} from "../../model/visibleReplyPresentation";

const { markdownRenderSpy } = vi.hoisted(() => ({
  markdownRenderSpy: vi.fn(),
}));
const analytics = vi.hoisted(() => ({ begin: vi.fn(), finish: vi.fn() }));
vi.mock("../../../../analytics/client", () => ({
  commaAnalyticsIdentity: () => "test-user",
  captureCommaExperience: vi.fn(),
  beginCommaMessageSend: (surface: string) => {
    analytics.begin(surface);
    return analytics.finish;
  },
}));

vi.mock("@comma/ui", async (importOriginal) => {
  const [actual, React] = await Promise.all([
    importOriginal<typeof import("@comma/ui")>(),
    import("react"),
  ]);

  return {
    ...actual,
    MarkdownStream: ({
      blurAnimation,
      content,
      className,
      final,
      maxAnimatedCharacters,
      showCursor,
      smoothStreaming,
      streamId,
    }: {
      blurAnimation?: {
        activeCharacters?: number;
        blurRadiusPx?: number;
        characterDelayMs?: number;
        durationMs?: number;
        initialOpacity?: number;
        translateYEm?: number;
      };
      content: string;
      className?: string;
      final?: boolean;
      maxAnimatedCharacters?: number;
      showCursor?: boolean;
      smoothStreaming?: boolean | "auto";
      streamId?: string;
    }) => {
      markdownRenderSpy(content);
      // Honor the real link-decorator context so decorator wiring is
      // observable through this mock, exactly as CommaLinkNode would apply it
      // to an external anchor.
      const decorator = React.useContext(actual.MarkdownStreamLinkDecoratorContext);
      const markdownLink = /^\[([^\]]+)\]\((https?:\/\/[^)]+)\)$/.exec(content);
      const anchor = markdownLink
        ? React.createElement("a", { href: markdownLink[2] }, markdownLink[1])
        : undefined;
      return React.createElement(
        "div",
        {
          className,
          "data-blur-animation": JSON.stringify(blurAnimation),
          "data-final": String(final),
          "data-max-animated-characters": String(maxAnimatedCharacters),
          "data-show-cursor": String(Boolean(showCursor)),
          "data-smooth-streaming": String(smoothStreaming),
          "data-testid": streamId ? `markdown-${streamId}` : undefined,
        },
        anchor && markdownLink
          ? decorator
            ? decorator({ anchor, href: markdownLink[2] as string })
            : anchor
          : content
      );
    },
  };
});

describe("ConversationView", () => {
  it.each(["route", "side-chat"] as const)(
    "keeps media menu availability within the %s file surface",
    async (variant) => {
      const attachment = localImageAttachment(0);
      const actions = createActions();
      actions.previewLocalFile = vi.fn(async () => ({
        url: "blob:menu-image",
        release: vi.fn(),
      }));
      renderConversation(
        <ConversationViewWithDraft
          actions={actions}
          state={state({
            messages: [message("msg_menu", "user", "", { attachments: [attachment] })],
          })}
          variant={variant}
        />
      );
      const image = await screen.findByRole("img", { name: attachment.fileName! });
      fireEvent.contextMenu(image, { clientX: 100, clientY: 100 });
      if (variant === "route") {
        expect(
          await screen.findByRole("menu", { name: "Image actions" })
        ).toBeVisible();
      } else {
        expect(screen.queryByRole("menu", { name: "Image actions" })).toBeNull();
      }
    }
  );

  it.each([
    ["runtime", "accepted"],
    ["runtime", "failed"],
    ["server", "accepted"],
    ["server", "failed"],
  ] as const)(
    "tracks %s submission %s without capturing message content",
    async (boundary, outcome) => {
      analytics.begin.mockClear();
      analytics.finish.mockClear();
      let resolve!: () => void;
      let reject!: (error: Error) => void;
      const completion = new Promise<void>((yes, no) => {
        resolve = yes;
        reject = no;
      });
      const actions = createActions();
      actions.send = vi.fn(() =>
        boundary === "runtime" ? { accepted: completion } : completion
      );
      const view = renderConversation(
        <ConversationViewWithDraft
          actions={actions}
          state={state({ draft: "private message contents" })}
          variant="route"
        />
      );
      fireEvent.click(await screen.findByRole("button", { name: "Send message" }));
      expect(analytics.begin.mock.calls).toEqual([["route"]]);
      await act(async () => {
        if (outcome === "accepted") resolve();
        else reject(new Error("private provider error"));
      });
      expect(analytics.finish.mock.calls).toEqual([[outcome, boundary]]);
      expect(actions.send).toHaveBeenCalledWith("private message contents", {
        skills: [],
      });
      view.unmount();
    }
  );

  afterEach(() => {
    toast.dismissAll();
    initializeCommaI18n(["en"]);
    markdownRenderSpy.mockClear();
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it("renders loading, terminal error, and empty ready states", async () => {
    const actions = createActions();
    const idle = renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({ conversation: undefined })}
      />
    );
    expect(screen.queryByTestId("task-review-action")).toBeNull();
    idle.unmount();

    const loading = renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({ conversation: undefined, status: "loading" })}
      />
    );

    const loadingStatus = await screen.findByRole("status", { name: "Loading…" });
    expect(loadingStatus).toHaveAttribute("aria-busy", "true");
    expect(screen.getByTestId("chat-title-loading")).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Chat" })).not.toBeInTheDocument();
    expect(loading.container.querySelector(".comma-chat-route")).toHaveClass(
      "bg-main-panel-bg"
    );
    loading.unmount();

    const error = renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          conversation: undefined,
          status: "error",
          errorKind: "unauthorized",
        })}
      />
    );
    expect(
      await screen.findByText("Your sign-in expired. Sign in again.")
    ).toBeInTheDocument();
    error.unmount();

    const empty = renderConversation(
      <ConversationViewWithDraft actions={actions} state={state({ messages: [] })} />
    );
    expect(empty.container.querySelector(".comma-chat-back")).toBeNull();
    expect(screen.queryByTestId("chat-title-loading")).not.toBeInTheDocument();
    expect(
      await screen.findByText("You start. Comma does the rest.")
    ).toBeInTheDocument();
    expect(
      screen.getByText("Every conversation starts and happens here")
    ).toBeInTheDocument();
    empty.unmount();

    renderConversation(
      <CommaI18nProvider locale="zh-CN">
        <ConversationViewWithDraft actions={actions} state={state({ messages: [] })} />
      </CommaI18nProvider>
    );
    expect(
      await screen.findByRole("heading", { name: "你起个头，剩下的交给 Comma" })
    ).toBeInTheDocument();
  });

  it.each([
    ["loading", state({ status: "loading" })],
    ["an unavailable read", state({ status: "error", errorKind: "unauthorized" })],
  ])(
    "keeps a canonical Conversation sendable while the channel reports %s",
    async (_label, degradedState) => {
      const actions = createActions();
      const draft = "继续发送";
      const rendered = renderConversation(
        <ConversationViewWithDraft
          actions={actions}
          state={{
            ...degradedState,
            draft,
            messages: [message("msg_existing", "assistant", "上一条消息")],
          }}
        />
      );

      const send = await screen.findByRole("button", { name: "Send message" });
      expect(send).toBeEnabled();
      fireEvent.click(send);
      expect(actions.send).toHaveBeenCalledOnce();
      expect(actions.send).toHaveBeenCalledWith(draft, { skills: [] });

      rendered.unmount();
    }
  );

  it("does not bind the Home task indicator layout to composer resize measurements", async () => {
    const observedTargets: Element[] = [];

    class MockResizeObserver {
      readonly disconnect = vi.fn();
      readonly observe = vi.fn((target: Element) => observedTargets.push(target));
      readonly unobserve = vi.fn();
    }

    vi.stubGlobal("ResizeObserver", MockResizeObserver);

    const rendered = renderStatefulConversation(state(), createActions(), "home");
    const layout = await screen.findByTestId("home-responsive-layout");
    const composer =
      rendered.container.querySelector<HTMLElement>(".comma-chat-composer");
    expect(layout).not.toBeNull();
    expect(composer).not.toBeNull();
    expect(composer).toHaveClass("ai-input-small-shell-motion");
    expect(observedTargets).not.toContain(composer);
    expect(layout!.style.getPropertyValue("--comma-home-composer-height")).toBe("");
  });

  it("uses the localized Comma assistant identity instead of the persisted Home chat title", async () => {
    renderConversation(
      <CommaI18nProvider locale="en">
        <ConversationViewWithDraft
          actions={createActions()}
          state={state({
            conversation: {
              id: "cnv_home",
              kind: "user_chat",
              status: "open",
              title: "聊天",
              group_id: "grp_1",
            },
          })}
          variant="home"
        />
      </CommaI18nProvider>
    );

    expect(
      await screen.findByRole("region", { name: "Comma assistant" })
    ).toBeInTheDocument();
    // Home has no route header: the identity lives on the region, not a title.
    expect(screen.queryByRole("heading", { level: 1 })).toBeNull();
    expect(screen.queryByText("聊天")).toBeNull();
  });

  it("keeps the localized fallback for an unnamed non-Home conversation", async () => {
    renderConversation(
      <CommaI18nProvider locale="zh-CN">
        <ConversationViewWithDraft
          actions={createActions()}
          state={state({
            conversation: {
              id: "cnv_untitled",
              kind: "user_chat",
              status: "open",
              title: "",
              group_id: "grp_1",
            },
          })}
        />
      </CommaI18nProvider>
    );

    expect(
      await screen.findByRole("heading", { level: 1, name: "聊天" })
    ).toBeInTheDocument();
    expect(screen.getByRole("region", { name: "会话" })).toBeInTheDocument();
  });

  it("labels task conversations with the canonical localized header status", async () => {
    const actions = createActions();
    renderConversation(
      <CommaI18nProvider locale="zh-CN">
        <ConversationViewWithDraft
          actions={actions}
          state={state({
            conversation: {
              id: "cnv_task",
              kind: "agent_task",
              status: "running",
              title: "Review task",
              group_id: "grp_1",
            },
          })}
        />
      </CommaI18nProvider>
    );

    const metadata = await screen.findByTestId("task-conversation-status");
    expect(
      screen.getByRole("heading", { level: 1, name: "Review task" })
    ).toBeVisible();
    expect(metadata).not.toHaveTextContent("任务");
    expect(metadata).toHaveTextContent("进行中");
    expect(metadata).not.toHaveTextContent("running");
  });

  it("renders ready-for-review metadata from the canonical status bucket", async () => {
    const actions = createActions();
    renderConversation(
      <CommaI18nProvider locale="zh-CN">
        <ConversationViewWithDraft
          actions={actions}
          state={state({
            conversation: {
              id: "cnv_task_review",
              kind: "agent_task",
              status: "ready_for_review",
              title: "Review task",
              group_id: "grp_1",
            },
          })}
        />
      </CommaI18nProvider>
    );

    const metadata = await screen.findByTestId("task-conversation-status");
    expect(metadata).not.toHaveTextContent("任务");
    expect(metadata).toHaveTextContent("待审核");
    expect(metadata).not.toHaveTextContent("ready_for_review");
  });

  it("accepts only a versioned one-shot Task review", async () => {
    const acceptTaskReview = vi.fn().mockResolvedValue(undefined);
    const actions = { ...createActions(), acceptTaskReview };
    const reviewable = state({
      conversation: {
        id: "cnv_task_review",
        kind: "agent_task",
        review_version: 2,
        status: "ready_for_review",
        title: "Review task",
        group_id: "grp_1",
      },
    });

    const rendered = renderConversation(
      <ConversationViewWithDraft actions={actions} state={reviewable} />
    );

    fireEvent.click(await screen.findByRole("button", { name: "Done" }));
    await waitFor(() => expect(acceptTaskReview).toHaveBeenCalledWith(2));
    // The accept control lives in the details panel on the Task route; the
    // transcript tail card and the header carry no second copy of it.
    expect(screen.queryByTestId("task-review-action")).toBeNull();
    expect(
      rendered.container.querySelector(".comma-chat-header .comma-task-review-action")
    ).toBeNull();
    expect(await screen.findByTestId("task-panel-properties")).toContainElement(
      screen.getByRole("button", { name: "Marking done…" })
    );
    rendered.unmount();

    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          conversation: {
            ...reviewable.conversation!,
            schedule: {
              command: "Send the report",
              schedule_id: "sch1_review",
            },
          },
        })}
      />
    );

    expect(screen.queryByRole("button", { name: "Done" })).toBeNull();
  });

  it("swaps the panel's status in two beats and lets Done leave with the old one", async () => {
    const acceptTaskReview = vi.fn().mockResolvedValue(undefined);
    const actions = { ...createActions(), acceptTaskReview };
    const reviewable = state({
      conversation: {
        id: "cnv_task_review",
        kind: "agent_task",
        review_version: 2,
        status: "ready_for_review",
        title: "Review task",
        group_id: "grp_1",
      },
    });
    const rendered = renderStatefulConversation(reviewable, actions, "route");

    const status = await screen.findByTestId("task-conversation-status");
    expect(status).toHaveTextContent("Needs Review");
    expect(status).not.toHaveAttribute("data-swapping");
    const doneWrapper = () =>
      rendered.container.querySelector(".comma-task-panel-done");
    expect(doneWrapper()).not.toHaveAttribute("data-leaving");

    fireEvent.click(screen.getByRole("button", { name: "Done" }));
    await waitFor(() => expect(acceptTaskReview).toHaveBeenCalledWith(2));
    act(() => {
      rendered.setState(
        state({ conversation: { ...reviewable.conversation!, status: "completed" } })
      );
    });

    // The old state stays through its exit, hidden from readers, in the same
    // cell as the new one; Done leaves alongside it, disabled.
    expect(status).toHaveAttribute("data-swapping", "true");
    const leaving = status.querySelector(
      '.comma-status-swap-layer[data-leaving="true"]'
    );
    expect(leaving).toHaveAttribute("aria-hidden", "true");
    expect(leaving).toHaveTextContent("Needs Review");
    expect(
      status.querySelector('.comma-status-swap-layer:not([data-leaving="true"])')
    ).toHaveTextContent("Done");
    expect(doneWrapper()).toHaveAttribute("data-leaving", "true");
    expect(doneWrapper()!.querySelector("button")).toBeDisabled();

    await waitFor(() => {
      expect(status).not.toHaveAttribute("data-swapping");
      expect(doneWrapper()).toBeNull();
    });
    expect(status.querySelectorAll(".comma-status-swap-layer")).toHaveLength(1);
    expect(status).toHaveTextContent("Done");
    expect(status).not.toHaveTextContent("Needs Review");
  });

  it("offers the details as a header popover once the route folds its column", async () => {
    class MockResizeObserver {
      readonly disconnect = vi.fn();
      readonly observe = vi.fn();
      readonly unobserve = vi.fn();
    }
    vi.stubGlobal("ResizeObserver", MockResizeObserver);
    const narrow = vi
      .spyOn(Element.prototype, "getBoundingClientRect")
      .mockReturnValue({
        bottom: 600,
        height: 600,
        left: 0,
        right: 800,
        toJSON: () => ({}),
        top: 0,
        width: 800,
        x: 0,
        y: 0,
      } as DOMRect);
    const folded = state({
      conversation: {
        id: "cnv_task_folded",
        kind: "agent_task",
        review_version: 1,
        status: "ready_for_review",
        title: "Folded task",
        group_id: "grp_1",
      },
    });

    const actions = { ...createActions(), acceptTaskReview: vi.fn() };
    const rendered = renderConversation(
      <ConversationViewWithDraft actions={actions} state={folded} />
    );

    try {
      const trigger = await screen.findByRole("button", {
        name: "Show task details",
      });
      expect(screen.getByTestId("task-conversation-body")).toHaveAttribute(
        "data-panel-open",
        "false"
      );
      await userEvent.click(trigger);
      const popover = await screen.findByTestId("task-panel-popover");
      expect(within(popover).getByTestId("task-panel-properties")).toContainElement(
        within(popover).getByRole("button", { name: "Done" })
      );
    } finally {
      narrow.mockRestore();
      vi.unstubAllGlobals();
      rendered.unmount();
    }
  });

  it("does not leak an accept error into another reviewable Task", async () => {
    const acceptTaskReview = vi.fn().mockRejectedValue(new Error("conflict"));
    const actions = { ...createActions(), acceptTaskReview };
    const rendered = renderStatefulConversation(
      state({
        conversation: {
          id: "cnv_task_review_a",
          kind: "agent_task",
          review_version: 2,
          status: "ready_for_review",
          title: "Review task A",
          group_id: "grp_1",
        },
      }),
      actions
    );

    fireEvent.click(await screen.findByRole("button", { name: "Done" }));
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "The Task changed before it could be accepted. Review it again."
    );

    act(() => {
      rendered.setState(
        state({
          conversation: {
            id: "cnv_task_review_b",
            kind: "agent_task",
            review_version: 7,
            status: "ready_for_review",
            title: "Review task B",
            group_id: "grp_1",
          },
        })
      );
    });

    expect(screen.queryByRole("alert")).toBeNull();
  });

  it("does not leak an in-flight accept into another reviewable Task", async () => {
    let resolveAccept: (() => void) | undefined;
    const acceptTaskReview = vi.fn().mockReturnValue(
      new Promise<void>((resolve) => {
        resolveAccept = resolve;
      })
    );
    const actions = { ...createActions(), acceptTaskReview };
    const rendered = renderStatefulConversation(
      state({
        conversation: {
          id: "cnv_task_review_a",
          kind: "agent_task",
          review_version: 2,
          status: "ready_for_review",
          title: "Review task A",
          group_id: "grp_1",
        },
      }),
      actions
    );

    fireEvent.click(await screen.findByRole("button", { name: "Done" }));
    expect(await screen.findByRole("button", { name: "Marking done…" })).toBeDisabled();

    act(() => {
      rendered.setState(
        state({
          conversation: {
            id: "cnv_task_review_b",
            kind: "agent_task",
            review_version: 7,
            status: "ready_for_review",
            title: "Review task B",
            group_id: "grp_1",
          },
        })
      );
    });

    expect(screen.getByRole("button", { name: "Done" })).toBeEnabled();

    await act(async () => {
      resolveAccept?.();
    });
  });

  it("keeps a successful accept latched until the canonical Task changes", async () => {
    const acceptTaskReview = vi.fn().mockResolvedValue(undefined);
    const actions = { ...createActions(), acceptTaskReview };
    const rendered = renderStatefulConversation(
      state({
        conversation: {
          id: "cnv_task_review",
          kind: "agent_task",
          review_version: 2,
          status: "ready_for_review",
          title: "Review task",
          group_id: "grp_1",
        },
      }),
      actions
    );

    fireEvent.click(await screen.findByRole("button", { name: "Done" }));
    await waitFor(() => expect(acceptTaskReview).toHaveBeenCalledWith(2));

    expect(screen.getByRole("button", { name: "Marking done…" })).toBeDisabled();

    act(() => {
      rendered.setState(
        state({
          conversation: {
            id: "cnv_task_review",
            kind: "agent_task",
            review_version: 2,
            status: "completed",
            title: "Review task",
            group_id: "grp_1",
          },
        })
      );
    });

    expect(screen.queryByTestId("task-review-action")).toBeNull();
  });

  it("renders pending failure actions without moving failed text back into the composer", async () => {
    const actions = createActions();
    const pending = {
      ...pendingSend("req_1", "再补充一下各项目的人力占用情况。", "failed"),
      error: "Billing is temporarily unavailable. Try again later.",
    };
    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          messages: [pendingMessage(pending)],
          pending: [pending],
        })}
      />
    );

    const failedRow = await screen.findByTestId("chat-failed-row");
    expect(failedRow).toHaveTextContent(
      "Send failed · Billing is temporarily unavailable. Try again later."
    );
    expect(failedRow).not.toHaveTextContent("billing_unavailable");
    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveTextContent(/^$/);

    fireEvent.click(within(failedRow).getByRole("button", { name: "Retry" }));
    fireEvent.click(within(failedRow).getByRole("button", { name: "Discard" }));

    expect(actions.retry).toHaveBeenCalledWith("req_1");
    expect(actions.discard).toHaveBeenCalledWith("req_1");
  });

  it("shows the out-of-credits card when a send fails for insufficient credits", async () => {
    const user = userEvent.setup();
    const previousHash = window.location.hash;
    const actions = createActions();
    const pending = {
      ...pendingSend("req_billing", "继续", "failed"),
      error: "You’re out of credits. Add credits or switch plans to continue.",
    };

    try {
      renderConversation(
        <ConversationViewWithDraft
          actions={actions}
          state={state({
            messages: [pendingMessage(pending)],
            pending: [pending],
          })}
        />
      );

      const card = await screen.findByTestId("chat-out-of-credits");
      expect(card).toHaveTextContent("Out of usage credits");
      expect(card).toHaveTextContent("Add credits or switch plans, then retry.");
      expect(screen.queryByTestId("chat-failed-row")).toBeNull();
      const cardActions = within(card).getAllByRole("button");
      expect(cardActions.map((button) => button.textContent)).toEqual([
        "Add credits",
        "Discard",
        "Retry",
      ]);
      const addCredits = within(card).getByRole("button", { name: "Add credits" });
      const discard = within(card).getByRole("button", { name: "Discard" });
      const retry = within(card).getByRole("button", { name: "Retry" });

      addCredits.focus();
      await user.tab();
      expect(discard).toHaveFocus();
      await user.tab();
      expect(retry).toHaveFocus();

      fireEvent.click(retry);
      fireEvent.click(discard);
      expect(actions.retry).toHaveBeenCalledWith("req_billing");
      expect(actions.discard).toHaveBeenCalledWith("req_billing");

      fireEvent.click(addCredits);
      expect(window.location.hash).toBe("#/settings?category=usage-billing");
    } finally {
      window.location.hash = previousHash;
    }
  });

  it("disables submit while draft attachments are uploading or failed", async () => {
    const actions = createActions();
    const uploading = renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          draft: "read this",
          draftAttachments: [
            {
              error: undefined,
              id: "att_1",
              isImage: false,
              name: "report.txt",
              path: undefined,
              size: 12,
              status: "uploading",
            },
          ],
        })}
      />
    );

    expect(await screen.findByRole("button", { name: "Send message" })).toBeDisabled();
    uploading.unmount();

    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          draft: "read this",
          draftAttachments: [
            {
              error: "文件超过 10MB 上限",
              id: "att_2",
              isImage: false,
              name: "huge.txt",
              path: undefined,
              size: 10_000_001,
              status: "failed",
            },
          ],
        })}
      />
    );

    const failedRow = await screen.findByTestId("chat-upload-error");
    expect(failedRow).toHaveTextContent("huge.txt upload failed");
    expect(failedRow).toHaveTextContent("文件超过 10MB 上限");
    expect(screen.getByRole("button", { name: "Send message" })).toBeDisabled();
    fireEvent.click(within(failedRow).getByRole("button", { name: "Retry upload" }));
    fireEvent.click(
      within(failedRow).getByRole("button", { name: "Remove attachment" })
    );
    expect(actions.retryAttachment).toHaveBeenCalledWith("att_2");
    expect(actions.removeAttachment).toHaveBeenCalledWith("att_2");
  });

  it("keeps an uploaded image loading until its own thumbnail is ready", async () => {
    const actions = createActions();
    let resolvePreview: (value: { release: () => void; url: string }) => void;
    const previewReady = new Promise<{ release: () => void; url: string }>(
      (resolve) => {
        resolvePreview = resolve;
      }
    );

    renderConversation(
      <ConversationViewWithDraft
        actions={{
          ...actions,
          previewLocalFile: () => previewReady,
        }}
        state={state({
          draftAttachments: [
            {
              error: undefined,
              id: `lfi1_${"a".repeat(43)}`,
              isImage: true,
              name: "shot.png",
              path: undefined,
              size: 1_024,
              status: "uploaded",
            },
          ],
        })}
      />
    );

    // The upload is done but the thumbnail is not decoded yet. Falling through
    // to "ready" here would paint the placeholder fill for a frame, which
    // reads as a wrong image flashing between the spinner and the real one.
    const tile = await screen.findByTestId("image-attachment");
    await waitFor(() =>
      expect(tile.querySelector('[data-state="loading"]')).not.toBeNull()
    );
    expect(screen.queryByRole("img", { name: "shot.png" })).toBeNull();

    await act(async () => {
      resolvePreview({ release: () => {}, url: "blob:local/shot.png" });
      await Promise.resolve();
    });

    const image = await screen.findByRole("img", { name: "shot.png" });
    expect(image).toHaveAttribute("src", "blob:local/shot.png");
  });

  it("aggregates multiple upload failures into a single toast", async () => {
    const actions = createActions();
    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          draft: "three broken images",
          draftAttachments: [
            failedImageAttachment("att_a", "a.png"),
            failedImageAttachment("att_b", "b.png"),
            failedImageAttachment("att_c", "c.png"),
          ],
        })}
      />
    );

    const failedToast = await screen.findByTestId("chat-upload-error");
    expect(screen.getAllByTestId("chat-upload-error")).toHaveLength(1);
    expect(failedToast).toHaveTextContent("3 attachments failed to upload");
    // Identical failure reasons collapse into the shared detail line.
    expect(failedToast).toHaveTextContent(
      "Reconnect this workspace's Comma Connector."
    );
    fireEvent.click(within(failedToast).getByRole("button", { name: "Retry upload" }));
    expect(actions.retryAttachment).toHaveBeenCalledTimes(3);
    expect(actions.retryAttachment).toHaveBeenCalledWith("att_a");
    expect(actions.retryAttachment).toHaveBeenCalledWith("att_c");
    fireEvent.click(
      within(failedToast).getByRole("button", { name: "Remove attachment" })
    );
    expect(actions.removeAttachment).toHaveBeenCalledTimes(3);
  });

  it("keeps simultaneous composer recovery toasts independently owned", async () => {
    const firstActions = createActions();
    const secondActions = createActions();

    function SimultaneousComposers() {
      const [firstResolved, setFirstResolved] = useState(false);
      return (
        <>
          <button onClick={() => setFirstResolved(true)} type="button">
            Resolve first producer
          </button>
          <ConversationViewWithDraft
            actions={firstActions}
            state={state({
              conversation: {
                id: "cnv_first",
                kind: "user_chat",
                status: "active",
                title: "First",
                group_id: "grp_1",
              },
              draftAttachments: firstResolved
                ? []
                : [failedImageAttachment("att_first", "first.png")],
            })}
          />
          <ConversationViewWithDraft
            actions={secondActions}
            state={state({
              conversation: {
                id: "cnv_second",
                kind: "user_chat",
                status: "active",
                title: "Second",
                group_id: "grp_1",
              },
              draftAttachments: [failedImageAttachment("att_second", "second.png")],
            })}
          />
        </>
      );
    }

    renderConversation(<SimultaneousComposers />);
    await waitFor(() =>
      expect(screen.getAllByTestId("chat-upload-error")).toHaveLength(2)
    );

    fireEvent.click(screen.getByRole("button", { name: "Resolve first producer" }));

    await waitFor(() =>
      expect(screen.getAllByTestId("chat-upload-error")).toHaveLength(1)
    );
    expect(screen.getByTestId("chat-upload-error")).toHaveTextContent("second.png");
  });

  it("keeps side chat immediately reusable while authoritative pending rows animate", async () => {
    const geometry = mockOutgoingBubbleGeometry();

    const onSend = vi.fn();
    try {
      const view = renderConversation(<SideChatSendLifecycleHarness onSend={onSend} />);

      fireEvent.click(await screen.findByRole("button", { name: "Send message" }));

      await waitFor(() => expect(onSend).toHaveBeenCalledWith("Ship renderer parity"));
      expect(view.container.querySelectorAll('[data-source="pending"]')).toHaveLength(
        1
      );
      const firstOutgoingBubble = await waitFor(() => {
        const bubble = view.container.querySelector<HTMLElement>(
          '.comma-chat-user-bubble[data-outgoing-presentation="flying"]'
        );
        expect(bubble).not.toBeNull();
        return bubble!;
      });
      expect(screen.getByTestId("chat-empty-exiting")).toBeInTheDocument();
      const textbox = screen.getByRole("textbox", { name: "AI prompt" });
      expect(textbox).toBeEnabled();
      expect(textbox).toHaveTextContent(/^$/);
      expect(screen.getByRole("button", { name: "Send message" })).toBeDisabled();
      expect(screen.queryByTestId("ai-input-submit-spinner")).toBeNull();

      typeIntoComposerRichEditor(textbox, "Send a second thought");
      const secondSendButton = screen.getByRole("button", { name: "Send message" });
      expect(secondSendButton).toBeEnabled();
      expect(firstOutgoingBubble).toBeInTheDocument();
      fireEvent.click(secondSendButton);

      await waitFor(() =>
        expect(onSend).toHaveBeenNthCalledWith(2, "Send a second thought")
      );
      await waitFor(() =>
        expect(view.container.querySelectorAll('[data-source="pending"]')).toHaveLength(
          2
        )
      );
      await waitFor(() =>
        expect(
          view.container.querySelectorAll(
            '.comma-chat-user-bubble[data-outgoing-presentation="flying"]'
          )
        ).toHaveLength(2)
      );
      expect(view.container.querySelectorAll(".comma-chat-user-bubble")).toHaveLength(
        2
      );
      expect(textbox).toHaveTextContent(/^$/);
      expect(screen.queryByTestId("ai-input-submit-spinner")).toBeNull();
    } finally {
      geometry.mockRestore();
    }
  });

  it("keeps the outgoing transition through a plain web completion rejection", async () => {
    const geometry = mockOutgoingBubbleGeometry();
    let failSend: (() => void) | undefined;
    try {
      const view = renderConversation(
        <PlainPromiseFailureHarness
          onFailureReady={(fail) => {
            failSend = fail;
          }}
        />
      );

      fireEvent.click(await screen.findByRole("button", { name: "Send message" }));

      const pendingArticle = containerArticle(
        view.container,
        "pending:req_web_failure"
      );
      const pendingBubble = pendingArticle.querySelector<HTMLElement>(
        ".comma-chat-user-bubble"
      );
      await waitFor(() =>
        expect(pendingBubble).toHaveAttribute("data-outgoing-presentation", "flying")
      );
      expect(failSend).toBeDefined();

      await act(async () => {
        failSend?.();
        await Promise.resolve();
      });

      expect(await screen.findByTestId("chat-failed-row")).toHaveTextContent(
        "Send failed · Billing is temporarily unavailable. Try again later."
      );
      expect(containerArticle(view.container, "pending:req_web_failure")).toBe(
        pendingArticle
      );
      expect(pendingArticle.querySelector(".comma-chat-user-bubble")).toBe(
        pendingBubble
      );
      expect(pendingBubble).toHaveAttribute("data-outgoing-presentation", "flying");
      expect(view.container.querySelectorAll(".comma-chat-user-bubble")).toHaveLength(
        1
      );
    } finally {
      geometry.mockRestore();
    }
  });

  it("keeps one explicit outgoing transition and its destination DOM through ACK", async () => {
    const geometry = mockOutgoingBubbleGeometry();
    const animate = vi.fn(
      (
        _keyframes: Keyframe[] | PropertyIndexedKeyframes,
        _options?: number | KeyframeAnimationOptions
      ) =>
        ({
          cancel: vi.fn(),
          pause: vi.fn(),
          play: vi.fn(),
          currentTime: null,
          finished: new Promise<Animation>(() => {}),
        }) as unknown as Animation
    );
    const animateDescriptor = Object.getOwnPropertyDescriptor(
      Element.prototype,
      "animate"
    );
    Object.defineProperty(Element.prototype, "animate", {
      configurable: true,
      value: animate,
    });

    const pending = message("pending:req_motion", "user", "带动画进入", {
      clientRequestId: "req_motion",
      delivery: "sending",
      source: "pending",
    });
    const launch: ChatOutgoingLaunch = {
      existingTurnKeys: new Set(),
      expiresAt: Date.now() + 4_000,
      id: 41,
      sourceFrame: {
        bottom: 736,
        height: 64,
        left: 144,
        right: 536,
        top: 672,
        width: 392,
      },
      startedFromEmpty: false,
      text: "带动画进入",
    };

    try {
      const view = render(
        <ConversationThread
          messages={[pending]}
          onDiscard={() => {}}
          onRetry={() => {}}
          outgoingLaunches={[launch]}
          groupId="grp_1"
          workspaceId="wsp_1"
        />
      );
      const pendingArticle = containerArticle(view.container, "pending:req_motion");
      const pendingBubble = pendingArticle.querySelector<HTMLElement>(
        ".comma-chat-user-bubble"
      );

      expect(pendingBubble).not.toBeNull();
      await waitFor(() =>
        expect(pendingBubble).toHaveAttribute("data-outgoing-presentation", "flying")
      );
      expect(pendingBubble).toHaveAttribute("popover", "manual");
      const pendingSlot = pendingBubble?.closest<HTMLElement>(
        ".comma-chat-user-bubble-slot"
      );
      expect(pendingSlot).toHaveAttribute("data-outgoing-presentation-slot", "true");
      expect(pendingSlot).toHaveStyle({ height: "64px", width: "220px" });
      expect(view.container.querySelectorAll(".comma-chat-user-bubble")).toHaveLength(
        1
      );
      // The turn, slot, bubble, and text share one playback clock.
      expect(animate).toHaveBeenCalledTimes(4);
      const originalAnimations = animate.mock.results.map((result) => result.value);
      for (const animation of originalAnimations) {
        expect(animation.pause).toHaveBeenCalledOnce();
        expect(animation.currentTime).toBe(0);
      }
      await waitFor(() => {
        for (const animation of originalAnimations) {
          expect(animation.play).toHaveBeenCalledOnce();
        }
      });
      const content = pendingBubble?.querySelector(".comma-chat-user-bubble-content");
      const textAnimationIndex = animate.mock.contexts.indexOf(content);
      expect(textAnimationIndex).toBeGreaterThanOrEqual(0);
      const textFrames = animate.mock.calls[textAnimationIndex]![0];
      expect(Array.isArray(textFrames)).toBe(true);
      expect(
        (textFrames as Keyframe[])
          .filter((frame) => frame.transform !== undefined)
          .every((frame) => String(frame.transform).startsWith("translate3d("))
      ).toBe(true);

      view.rerender(
        <ConversationThread
          messages={[
            message("msg_server", "user", "带动画进入", {
              clientRequestId: "req_motion",
              delivery: "sent",
              source: "server",
            }),
          ]}
          onDiscard={() => {}}
          onRetry={() => {}}
          outgoingLaunches={[launch]}
          groupId="grp_1"
          workspaceId="wsp_1"
        />
      );

      const acknowledgedArticle = containerArticle(view.container, "msg_server");
      expect(acknowledgedArticle).toBe(pendingArticle);
      expect(acknowledgedArticle.querySelector(".comma-chat-user-bubble")).toBe(
        pendingBubble
      );
      expect(pendingBubble).toHaveAttribute("data-outgoing-presentation", "flying");
      expect(view.container.querySelectorAll(".comma-chat-user-bubble")).toHaveLength(
        1
      );
      expect(animate).toHaveBeenCalledTimes(4);
      for (const animation of originalAnimations) {
        expect(animation.cancel).not.toHaveBeenCalled();
        expect(animation.play).toHaveBeenCalledOnce();
      }
    } finally {
      geometry.mockRestore();
      if (animateDescriptor) {
        Object.defineProperty(Element.prototype, "animate", animateDescriptor);
      } else {
        Reflect.deleteProperty(Element.prototype, "animate");
      }
    }
  });

  it("keeps reduced-motion outgoing bubbles in flow during the single cross-fade", async () => {
    const geometry = mockOutgoingBubbleGeometry();
    const animate = vi.fn(
      (
        _keyframes: Keyframe[] | PropertyIndexedKeyframes,
        _options?: number | KeyframeAnimationOptions
      ) =>
        ({
          cancel: vi.fn(),
          pause: vi.fn(),
          play: vi.fn(),
          currentTime: null,
          finished: new Promise<Animation>(() => {}),
        }) as unknown as Animation
    );
    const animateDescriptor = Object.getOwnPropertyDescriptor(
      Element.prototype,
      "animate"
    );
    Object.defineProperty(Element.prototype, "animate", {
      configurable: true,
      value: animate,
    });
    document.documentElement.setAttribute("data-comma-reduced-motion", "true");

    const pending = message("pending:req_reduced_motion", "user", "平静地进入", {
      clientRequestId: "req_reduced_motion",
      delivery: "sending",
      source: "pending",
    });
    const launch: ChatOutgoingLaunch = {
      existingTurnKeys: new Set(),
      expiresAt: Date.now() + 4_000,
      id: 42,
      sourceFrame: {
        bottom: 736,
        height: 64,
        left: 144,
        right: 536,
        top: 672,
        width: 392,
      },
      startedFromEmpty: false,
      text: "平静地进入",
    };

    try {
      const view = render(
        <ConversationThread
          messages={[pending]}
          onDiscard={() => {}}
          onRetry={() => {}}
          outgoingLaunches={[launch]}
          groupId="grp_1"
          workspaceId="wsp_1"
        />
      );
      const pendingArticle = containerArticle(
        view.container,
        "pending:req_reduced_motion"
      );
      const pendingBubble = pendingArticle.querySelector<HTMLElement>(
        ".comma-chat-user-bubble"
      );
      const pendingSlot = pendingBubble?.closest<HTMLElement>(
        ".comma-chat-user-bubble-slot"
      );

      expect(pendingBubble).not.toBeNull();
      await waitFor(() =>
        expect(pendingBubble).toHaveAttribute("data-outgoing-presentation", "flying")
      );
      expect(pendingBubble).not.toHaveAttribute("popover");
      expect(pendingBubble).not.toHaveStyle({ position: "fixed" });
      expect(pendingSlot).not.toHaveAttribute("data-outgoing-presentation-slot");
      expect(pendingSlot?.style.width).toBe("");
      expect(pendingSlot?.style.height).toBe("");
      expect(pendingBubble?.parentElement).toBe(pendingSlot);
      expect(animate).toHaveBeenCalledTimes(1);

      const [frames, timing] = animate.mock.calls[0]!;
      expect(frames).toEqual([
        { offset: 0, opacity: 0, transform: "none" },
        { offset: 1, opacity: 1, transform: "none" },
      ]);
      expect(timing).toMatchObject({
        duration: 150,
        easing: "linear",
        fill: "both",
      });

      view.rerender(
        <ConversationThread
          messages={[
            message("msg_reduced_motion", "user", "平静地进入", {
              clientRequestId: "req_reduced_motion",
              delivery: "sent",
              source: "server",
            }),
          ]}
          onDiscard={() => {}}
          onRetry={() => {}}
          outgoingLaunches={[launch]}
          groupId="grp_1"
          workspaceId="wsp_1"
        />
      );

      const acknowledgedArticle = containerArticle(
        view.container,
        "msg_reduced_motion"
      );
      expect(acknowledgedArticle).toBe(pendingArticle);
      expect(acknowledgedArticle.querySelector(".comma-chat-user-bubble")).toBe(
        pendingBubble
      );
      expect(animate).toHaveBeenCalledTimes(1);
    } finally {
      document.documentElement.removeAttribute("data-comma-reduced-motion");
      geometry.mockRestore();
      if (animateDescriptor) {
        Object.defineProperty(Element.prototype, "animate", animateDescriptor);
      } else {
        Reflect.deleteProperty(Element.prototype, "animate");
      }
    }
  });

  it("does not fabricate side-chat typing and animates only canonical replies", () => {
    const prompt = message("msg_prompt", "user", "Prompt");
    const view = render(
      <ConversationThread
        messages={[prompt]}
        onDiscard={() => {}}
        onRetry={() => {}}
        variant="side-chat"
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(screen.queryByTestId("chat-assistant-typing")).toBeNull();
    expect(view.container.querySelector(".comma-side-chat-typing-dots")).toBeNull();

    view.rerender(
      <ConversationThread
        messages={[prompt, message("msg_reply", "assistant", "Committed reply")]}
        onDiscard={() => {}}
        onRetry={() => {}}
        variant="side-chat"
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );
    const committed = screen.getByText("Committed reply").closest("article");
    expect(committed).toHaveClass("comma-side-chat-assistant-entry");
  });

  it("keeps the empty Side Chat shadow unclipped and masks conversation content", () => {
    const view = render(
      <ConversationThread
        messages={[]}
        onDiscard={() => {}}
        onRetry={() => {}}
        variant="side-chat"
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(view.container.querySelector('[data-slot="scroll-area"]')).toHaveAttribute(
      "data-edge-effect",
      "none"
    );
    expect(view.container.querySelector('[data-slot="scroll-area"]')).toHaveAttribute(
      "data-edge-mask",
      "false"
    );
    expect(screen.getByTestId("chat-empty").querySelector("img")).toHaveAttribute(
      "src",
      "brand/comma/icon.png"
    );

    view.rerender(
      <ConversationThread
        messages={[]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(view.container.querySelector('[data-slot="scroll-area"]')).toHaveAttribute(
      "data-edge-effect",
      "mask"
    );
    expect(view.container.querySelector('[data-slot="scroll-area"]')).toHaveAttribute(
      "data-edge-mask",
      "true"
    );
  });

  it("presents the assistant draft as a response bubble", async () => {
    const view = renderStatefulConversation(
      state({ messages: [message("msg_latest_user", "user", "没有活动")] })
    );
    await screen.findByText("没有活动");
    const latestUserRow = view.container.querySelector(
      '[data-message-id="msg_latest_user"]'
    );

    expect(latestUserRow).not.toBeNull();
    const participantStatusSlot = screen.getByTestId("participant-status-slot");
    expect(participantStatusSlot).toHaveAttribute("data-active", "false");
    const timestamp = screen.getByTestId("chat-conversation-time-msg_latest_user");
    expect(timestamp.nextElementSibling).toBe(latestUserRow);
    expect(latestUserRow?.nextElementSibling).toBe(participantStatusSlot);

    act(() => {
      view.setState(
        state({
          assistantDraft: {
            conversationId: "cnv_1",
            draftId: "draft_held",
            responseKey: "rsp_held",
            sourceMessageIds: ["msg_latest_user"],
            status: "completed",
            text: "等待 canonical",
          },
          messages: [message("msg_latest_user", "user", "没有活动")],
        })
      );
    });
    const draft = screen.getByTestId("chat-assistant-draft");
    expect(draft).toHaveTextContent("等待 canonical");
    expect(latestUserRow?.nextElementSibling).toBe(draft);
    expect(draft.nextElementSibling).toBe(participantStatusSlot);
    expect(participantStatusSlot).toHaveAttribute("data-active", "false");
  });

  it("sends every message immediately while a reply is streaming", async () => {
    const onDraftChange = vi.fn();
    const onSend = vi.fn();
    renderConversation(
      <SideChatStreamingLifecycleHarness
        onDraftChange={onDraftChange}
        onSend={onSend}
      />
    );

    const textbox = await screen.findByRole("textbox", { name: "AI prompt" });
    expect(textbox).toBeEnabled();
    typeIntoComposerRichEditor(textbox, "Keep editing");
    expect(onDraftChange).toHaveBeenCalledWith("Keep editing");
    const sendButton = screen.getByRole("button", { name: "Send message" });
    expect(sendButton).toBeEnabled();
    expect(screen.queryByTestId("ai-input-submit-spinner")).toBeNull();

    fireEvent.click(sendButton);
    expect(onSend).toHaveBeenCalledWith("Keep editing", { skills: [] });
  });

  it("submits immediately with Cmd+Enter while a reply is streaming", async () => {
    const onDraftChange = vi.fn();
    const onSend = vi.fn();
    renderConversation(
      <SideChatStreamingLifecycleHarness
        onDraftChange={onDraftChange}
        onSend={onSend}
      />
    );

    const textbox = await screen.findByRole("textbox", { name: "AI prompt" });
    typeIntoComposerRichEditor(textbox, "Send this one");
    fireEvent.keyDown(textbox, { key: "Enter", metaKey: true });

    expect(onSend).toHaveBeenCalledWith("Send this one", { skills: [] });
  });

  it("sends immediately after a retained failed activity", async () => {
    const actions = createActions();
    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          activity: { status: "failed" },
          draft: "Recover after failure",
          messages: [message("msg_failed_activity", "user", "Original prompt")],
        })}
        variant="side-chat"
      />
    );

    fireEvent.click(await screen.findByRole("button", { name: "Send message" }));

    expect(actions.send).toHaveBeenCalledWith("Recover after failure", {
      skills: [],
    });
  });

  it("shows localized active feedback without exposing runtime wait text", async () => {
    const prompt = message("msg_waiting", "user", "Wait for the agent");

    renderConversation(
      <ConversationViewWithDraft
        actions={createActions()}
        state={state({
          awaitingReply: true,
          awaitingSince: Date.now() - 3_000,
          messages: [prompt],
          participantStatus: {
            conversationId: "cnv_1",
            participantId: "ptp_1",
            state: "active",
            status: "is waiting for user approval",
            updatedAt: 1_780_000_000_100,
          },
        })}
      />
    );

    expect(await screen.findByText("Thinking")).toBeInTheDocument();
    expect(screen.queryByText("is waiting for user approval")).toBeNull();
    expect(screen.queryByRole("button", { name: "Stop waiting" })).toBeNull();
  });

  it("places Side Chat tool execution after the reply as a separate bubble", async () => {
    const prompt = message("msg_tool_prompt", "user", "Check the calendar");
    const reply = message("msg_tool_reply", "assistant", "I will check that now.");
    const view = renderConversation(
      <ConversationViewWithDraft
        actions={createActions()}
        state={state({
          messages: [prompt, reply],
          activity: {
            phase: "execution",
            status: "running",
            toolName: "calendar.list_items",
            summaryClass: "public",
            summary: "Working",
          },
          participantStatus: {
            conversationId: "cnv_1",
            participantId: "ptp_1",
            state: "active",
            status: "is executing a tool...",
            updatedAt: 1,
          },
        })}
        variant="side-chat"
      />
    );
    const activity = await screen.findByTestId("participant-status-slot");
    const article = containerArticle(view.container, reply.messageId);
    expect(activity).toHaveAttribute("data-presentation", "tool-call");
    expect(activity).toHaveTextContent("Checking your calendar");
    expect(article).not.toContainElement(activity);
    expect(
      article.compareDocumentPosition(activity) & Node.DOCUMENT_POSITION_FOLLOWING
    ).toBe(Node.DOCUMENT_POSITION_FOLLOWING);
    expect(article).toHaveTextContent("I will check that now.");
  });

  it("words a participant error from its issue code, never the runtime's text", async () => {
    renderConversation(
      <CommaI18nProvider locale="zh-CN">
        <ConversationViewWithDraft
          actions={createActions()}
          state={state({
            messages: [message("msg_error", "user", "继续")],
            participantStatus: {
              conversationId: "cnv_1",
              issue: "model_unavailable",
              participantId: "ptp_1",
              state: "error",
              status: "error: model request failed.",
              updatedAt: 1_780_000_000_200,
            },
          })}
        />
      </CommaI18nProvider>
    );

    const status = await screen.findByText("模型暂时不可用，请稍后再试或换一个模型。");
    expect(screen.queryByText("error: model request failed.")).toBeNull();
    expect(status.closest('[data-slot="ai-activity"]')).toHaveAttribute(
      "data-status",
      "failed"
    );
  });
  it("keeps current-turn feedback after a pending user message", async () => {
    const actions = createActions();
    const prompt = message("msg_status_prompt", "user", "Run the work");
    const reply = message("msg_status_reply", "assistant", "Canonical reply");
    const failedPending = message("pending:req_status", "user", "Pending retry", {
      clientRequestId: "req_status",
      delivery: "failed",
      source: "pending",
    });
    const participantState: Partial<ConversationChannelState> = {
      awaitingReply: true,
      awaitingSince: Date.now() - 151_000,
      awaitingTimedOut: true,
      messages: [prompt, reply, failedPending],
      participantStatus: {
        conversationId: "cnv_1",
        participantId: "ptp_1",
        state: "active" as const,
        status: "is executing a tool...",
        updatedAt: 1_780_000_000_123,
      },
    };

    const rendered = renderConversation(
      <ConversationViewWithDraft actions={actions} state={state(participantState)} />
    );

    const status = await screen.findByText("Thinking");
    const lastMessage = containerArticle(rendered.container, failedPending.messageId);
    expect(
      lastMessage.compareDocumentPosition(status) & Node.DOCUMENT_POSITION_FOLLOWING
    ).toBe(Node.DOCUMENT_POSITION_FOLLOWING);
  });

  it("keeps Task participant feedback at the tail of an agent-only transcript", async () => {
    const rendered = renderStatefulConversation(
      state({
        conversation: {
          id: "cnv_task",
          kind: "agent_task",
          status: "in_progress",
          title: "Task",
          group_id: "grp_1",
        },
        messages: [
          message("msg_task_start", "assistant", "Task started"),
          message("msg_task_progress", "assistant", "Task progress"),
        ],
        participantStatuses: [
          {
            conversationId: "cnv_task",
            participantId: "ptp_worker",
            actorRole: "worker",
            name: "Worker",
            state: "active",
            status: "is thinking...",
            updatedAt: 1,
          },
        ],
      })
    );
    const slot = await screen.findByTestId("participant-status-slot");
    const lastMessage = containerArticle(rendered.container, "msg_task_progress");
    expect(
      lastMessage.compareDocumentPosition(slot) & Node.DOCUMENT_POSITION_FOLLOWING
    ).toBe(Node.DOCUMENT_POSITION_FOLLOWING);
    expect(slot).toHaveTextContent("Worker is thinking");
  });

  it("keeps a timed-out accepted send visible without a running participant", async () => {
    const participantState: Partial<ConversationChannelState> = {
      awaitingReply: true,
      awaitingSince: Date.now() - 151_000,
      awaitingTimedOut: true,
      messages: [message("msg_stopped", "user", "Wait for completion")],
      participantStatus: {
        conversationId: "cnv_1",
        participantId: "ptp_1",
        state: "stopped" as const,
        status: "",
        updatedAt: 1_780_000_000_456,
      },
    };

    renderConversation(
      <ConversationViewWithDraft
        actions={createActions()}
        state={state(participantState)}
      />
    );

    expect(await screen.findByTestId("participant-status-slot")).toHaveAttribute(
      "data-active",
      "true"
    );
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "data-state",
      "waiting"
    );
  });

  // Regression: a turn can fail before committing an assistant message while
  // the canonical Participant status still reads "stopped". Its source-bound
  // Activity terminal remains visible in the reply status row, without
  // inventing a model-specific cause.
  it("surfaces a failed turn in the reply status row while the participant is stopped", async () => {
    const failedTurnState: Partial<ConversationChannelState> = {
      activity: {
        phase: "thinking",
        responseKey: "rsp_1",
        sequence: 3,
        status: "failed",
        summaryClass: "generic",
      },
      awaitingReply: false,
      messages: [message("msg_failed_turn", "user", "刚才那个会议的记录发一下")],
      participantStatus: {
        conversationId: "cnv_1",
        participantId: "ptp_1",
        state: "stopped" as const,
        status: "",
        updatedAt: 1_780_000_000_789,
      },
    };

    renderConversation(
      <ConversationViewWithDraft
        actions={createActions()}
        state={state(failedTurnState)}
      />
    );

    expect(await screen.findByText("Generation failed")).toBeInTheDocument();
    const slot = screen.getByTestId("participant-status-slot");
    expect(slot).toHaveAttribute("data-active", "true");
    expect(slot).toHaveAttribute("data-state", "error");
  });

  it("updates the live region node for consecutive assistant replies", async () => {
    const conversation = renderStatefulConversation(
      state({ messages: [message("msg_1", "user", "先查一下。")] })
    );
    await screen.findByText("先查一下。");

    const liveRegion = conversation.container.querySelector(
      '.app-sr-only[aria-live="polite"]'
    );
    expect(liveRegion).not.toBeNull();
    expect(liveRegion!.textContent).toBe("");

    act(() => {
      conversation.setState(
        state({
          messages: [
            message("msg_1", "user", "先查一下。"),
            message("msg_2", "assistant", "第一条回复。"),
          ],
        })
      );
    });
    await waitFor(() =>
      expect(liveRegion).toHaveTextContent("A new reply has arrived")
    );
    await screen.findByText("第一条回复。");
    const firstAnnouncementNode = liveRegion!.firstElementChild;

    act(() => {
      conversation.setState(
        state({
          messages: [
            message("msg_1", "user", "先查一下。"),
            message("msg_2", "assistant", "第一条回复。"),
            message("msg_3", "assistant", "第二条回复。"),
          ],
        })
      );
    });

    await waitFor(() =>
      expect(liveRegion!.firstElementChild).not.toBe(firstAnnouncementNode)
    );
    expect(liveRegion).toHaveTextContent("A new reply has arrived");
  });

  it("renders conversation ref cards and generated file cards from content blocks", async () => {
    const actions = createActions();
    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          messages: [
            message("msg_1", "assistant", "已创建任务。", {
              attachments: [
                {
                  blockType: "file",
                  fileName: "report.pdf",
                  mimeType: "application/pdf",
                  size: 2048,
                  title: "report.pdf",
                },
              ],
              refs: [
                {
                  conversationId: "cnv_task",
                  kind: "agent_task",
                  title: "部署报告",
                },
              ],
            }),
          ],
        })}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const card = await screen.findByTestId("chat-ref-card-cnv_task");
    expect(card).toHaveTextContent("Task");
    expect(card).toHaveTextContent("部署报告");
    const fileCard = screen
      .getByText("report.pdf")
      .closest<HTMLElement>(".chat-panel-file");
    expect(fileCard).not.toBeNull();
    expect(fileCard).toHaveTextContent("report.pdf");
    expect(fileCard).toHaveTextContent("PDF · 2KB");
    expect(within(fileCard!).queryByRole("button")).not.toBeInTheDocument();

    fireEvent.click(card);
    expect(await screen.findByTestId("routed-conversation")).toHaveTextContent(
      "cnv_task"
    );
  });

  it.each([
    {
      name: "keeps the generated file card without an inline download button",
      variant: undefined,
    },
    {
      name: "does not offer generated-file downloads on the Side Chat surface",
      variant: "side-chat" as const,
    },
  ])("$name", async ({ variant }) => {
    const actions = createActions();
    const fetchConversationAttachment = vi
      .fn()
      .mockResolvedValue(new Blob(["report bytes"], { type: "application/pdf" }));
    const api = {
      fetchConversationAttachment,
    } as Partial<CommaApiClient> as CommaApiClient;

    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        api={api}
        groupId="grp_1"
        state={state({
          messages: [
            message("msg_1", "assistant", "报告好了。", {
              attachments: [
                {
                  attachmentIndex: 2,
                  blockType: "file",
                  fileName: "report.pdf",
                  mimeType: "application/pdf",
                  size: 2048,
                  title: "report.pdf",
                },
              ],
            }),
          ],
        })}
        {...(variant ? { variant } : {})}
        workspaceId="wsp_1"
      />
    );

    const fileCard = await screen.findByTestId("chat-attachment-file-msg_1-0");
    expect(fileCard).toHaveTextContent("report.pdf");
    expect(
      within(fileCard).queryByRole("button", { name: "Download" })
    ).not.toBeInTheDocument();
    expect(fetchConversationAttachment).not.toHaveBeenCalled();
  });

  it("hands task ref cards to the sidebar opener without navigating the main view", async () => {
    const actions = createActions();
    const onOpenConversationRef = vi.fn();
    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        onOpenConversationRef={onOpenConversationRef}
        state={state({
          messages: [
            message("msg_1", "assistant", "已创建子任务。", {
              refs: [
                {
                  conversationId: "cnv_child_task",
                  kind: "agent_task",
                  title: "核对上线清单",
                },
              ],
            }),
          ],
        })}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const card = await screen.findByRole("button", {
      name: "Task: 核对上线清单",
    });
    fireEvent.click(card);

    expect(onOpenConversationRef).toHaveBeenCalledOnce();
    expect(onOpenConversationRef).toHaveBeenCalledWith({
      conversationId: "cnv_child_task",
      kind: "agent_task",
      title: "核对上线清单",
    });
    expect(screen.queryByTestId("routed-conversation")).toBeNull();
  });

  it("opens an external markdown link in Comma's browser sidebar", async () => {
    const actions = createActions();
    const onOpenInCommaBrowser = vi.fn();
    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        onOpenInCommaBrowser={onOpenInCommaBrowser}
        state={state({
          messages: [
            message(
              "msg_external_link",
              "assistant",
              "[Open docs](https://example.com/docs)"
            ),
          ],
        })}
      />
    );

    const link = await screen.findByRole("link", { name: "Open docs" });
    expect(fireEvent.click(link)).toBe(false);
    expect(onOpenInCommaBrowser).toHaveBeenCalledOnce();
    expect(onOpenInCommaBrowser).toHaveBeenCalledWith("https://example.com/docs");
    expect(screen.queryByTestId("routed-conversation")).toBeNull();
  });

  it("upgrades a rich external link to a hover preview through the workspace API", async () => {
    const actions = createActions();
    const getRecommendationLinkPreview = vi.fn().mockResolvedValue({
      additions: 12,
      author: { avatarUrl: null, login: "CatsJuice" },
      changedFiles: 3,
      deletions: 4,
      href: "https://github.com/AFK-surf/Comma/pull/845",
      kind: "github_pull_request",
      number: 845,
      repository: "AFK-surf/Comma",
      state: "merged",
      title: "feat(chat): add inline task elements",
      updatedAt: null,
    });
    const api = {
      getRecommendationLinkPreview,
    } as Partial<CommaApiClient> as CommaApiClient;
    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        api={api}
        groupId="grp_1"
        state={state({
          messages: [
            message(
              "msg_rich_link",
              "assistant",
              "[PR #845](https://github.com/AFK-surf/Comma/pull/845)"
            ),
          ],
        })}
        workspaceId="wsp_1"
      />
    );

    // The hover wrapper decorates the same single anchor — link semantics and
    // counts stay exactly as without it.
    const link = await screen.findByRole("link", { name: "PR #845" });
    expect(link).toHaveAttribute("href", "https://github.com/AFK-surf/Comma/pull/845");
    expect(screen.getAllByRole("link")).toHaveLength(1);
    expect(getRecommendationLinkPreview).not.toHaveBeenCalled();

    const user = userEvent.setup();
    setInteractionModality("pointer");
    await user.hover(link);

    const card = await screen.findByRole("tooltip", {}, { timeout: 3_000 });
    expect(getRecommendationLinkPreview).toHaveBeenCalledWith("wsp_1", {
      href: "https://github.com/AFK-surf/Comma/pull/845",
    });
    await waitFor(() =>
      expect(card).toHaveTextContent("feat(chat): add inline task elements")
    );
    expect(screen.getAllByRole("link")).toHaveLength(1);
  });

  it("leaves same-origin links to the app router", async () => {
    const actions = createActions();
    const onOpenInCommaBrowser = vi.fn();
    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        onOpenInCommaBrowser={onOpenInCommaBrowser}
        state={state({
          messages: [
            message(
              "msg_internal_link",
              "assistant",
              `[Open Inbox](${window.location.origin}/#/inbox)`
            ),
          ],
        })}
      />
    );

    const link = await screen.findByRole("link", { name: "Open Inbox" });
    expect(fireEvent.click(link)).toBe(true);
    expect(onOpenInCommaBrowser).not.toHaveBeenCalled();
  });

  it("opens a link context menu with external, Comma, and copy actions", async () => {
    const user = userEvent.setup();
    const actions = createActions();
    const onOpenInCommaBrowser = vi.fn();
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });
    const openSpy = vi.spyOn(window, "open").mockImplementation(() => null);

    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        onOpenInCommaBrowser={onOpenInCommaBrowser}
        state={state({
          messages: [
            message(
              "msg_link_menu",
              "assistant",
              "[Open docs](https://example.com/docs)"
            ),
          ],
        })}
      />
    );

    const link = await screen.findByRole("link", { name: "Open docs" });
    const expectedUrl = (link as HTMLAnchorElement).href;
    const contextMenuEvent = new MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
      clientX: 120,
      clientY: 80,
    });
    expect(fireEvent(link, contextMenuEvent)).toBe(false);
    expect(contextMenuEvent.defaultPrevented).toBe(true);

    expect(
      await screen.findByRole("menuitem", { name: "Open in External Browser" })
    ).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Open in Comma" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Copy Link" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Copy message" })).toBeInTheDocument();

    await user.click(screen.getByRole("menuitem", { name: "Open in Comma" }));
    expect(onOpenInCommaBrowser).toHaveBeenCalledWith(expectedUrl);

    fireEvent(
      link,
      new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: 120,
        clientY: 80,
      })
    );
    await user.click(screen.getByRole("menuitem", { name: "Copy Link" }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith(expectedUrl));

    fireEvent(
      link,
      new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: 120,
        clientY: 80,
      })
    );
    await user.click(screen.getByRole("menuitem", { name: "Copy message" }));
    await waitFor(() =>
      expect(writeText).toHaveBeenCalledWith("[Open docs](https://example.com/docs)")
    );

    fireEvent(
      link,
      new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: 120,
        clientY: 80,
      })
    );
    await user.click(
      screen.getByRole("menuitem", { name: "Open in External Browser" })
    );
    await waitFor(() =>
      expect(openSpy).toHaveBeenCalledWith(expectedUrl, "_blank", "noopener,noreferrer")
    );

    openSpy.mockRestore();
  });

  it("does not open the link menu for same-origin links", async () => {
    const actions = createActions();
    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        onOpenInCommaBrowser={vi.fn()}
        state={state({
          messages: [
            message(
              "msg_internal_context",
              "assistant",
              `[Open Inbox](${window.location.origin}/#/inbox)`
            ),
          ],
        })}
      />
    );

    const link = await screen.findByRole("link", { name: "Open Inbox" });
    const contextMenuEvent = new MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
    });
    fireEvent(link, contextMenuEvent);

    expect(contextMenuEvent.defaultPrevented).toBe(false);
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  it("stages a selected passage as a quote and sends it ahead of the body", async () => {
    const user = userEvent.setup();
    const actions = createActions();
    const accepted = Promise.resolve();
    actions.send = vi.fn(() => Object.assign(accepted, { accepted }));
    // jsdom has no layout, so the selection rect the bar anchors to must be
    // supplied; without it the bar refuses to place itself.
    const rect = vi
      .spyOn(Range.prototype, "getBoundingClientRect")
      .mockReturnValue(domRect(120, 200, 180, 20));

    try {
      renderConversation(
        <ConversationViewWithDraft
          actions={actions}
          state={state({
            draft: "这段是什么意思？",
            messages: [
              message("msg_quote", "assistant", "圆橡皮，中间留出金属箍空隙。"),
            ],
          })}
        />
      );

      selectChatText(await screen.findByText("圆橡皮，中间留出金属箍空隙。"), 0, 3);

      await user.click(await screen.findByRole("button", { name: "Add to chat" }));

      expect(await screen.findByLabelText("Quoted text: 圆橡皮")).toBeInTheDocument();
      // Staging consumes the selection, so the bar goes away with it.
      await waitFor(() =>
        expect(screen.queryByRole("button", { name: "Add to chat" })).toBeNull()
      );

      fireEvent.click(screen.getByRole("button", { name: "Send message" }));
      await act(async () => {
        await accepted;
      });

      expect(actions.send).toHaveBeenCalledWith(
        "Quoted from this conversation:\n> 圆橡皮\n\n这段是什么意思？",
        { skills: [] }
      );
      expect(screen.queryByLabelText("Quoted text: 圆橡皮")).toBeNull();
    } finally {
      rect.mockRestore();
    }
  });

  it("restores a rejected admission's quotes without replacing later quotes", async () => {
    const user = userEvent.setup();
    const actions = createActions();
    let rejectAccepted!: (error: Error) => void;
    const accepted = new Promise<void>((_resolve, reject) => {
      rejectAccepted = reject;
    });
    const completion = accepted.then(() => undefined);
    void completion.catch(() => undefined);
    actions.send = vi.fn(() => Object.assign(completion, { accepted }));
    const rect = vi
      .spyOn(Range.prototype, "getBoundingClientRect")
      .mockReturnValue(domRect(120, 200, 180, 20));

    try {
      renderConversation(
        <ConversationViewWithDraft
          actions={actions}
          state={state({
            draft: "Retry this message.",
            messages: [
              message("msg_rejected_quote", "assistant", "First quoted passage."),
              message("msg_later_quote", "assistant", "Later quoted passage."),
            ],
          })}
        />
      );

      selectChatText(await screen.findByText("First quoted passage."), 0, 5);
      await user.click(await screen.findByRole("button", { name: "Add to chat" }));
      expect(await screen.findByLabelText("Quoted text: First")).toBeInTheDocument();

      fireEvent.click(screen.getByRole("button", { name: "Send message" }));
      await waitFor(() =>
        expect(screen.queryByLabelText("Quoted text: First")).toBeNull()
      );

      selectChatText(await screen.findByText("Later quoted passage."), 0, 5);
      await user.click(await screen.findByRole("button", { name: "Add to chat" }));
      expect(await screen.findByLabelText("Quoted text: Later")).toBeInTheDocument();

      await act(async () => {
        rejectAccepted(new Error("attachment_admission_failed"));
        await Promise.resolve();
      });

      expect(await screen.findByLabelText("Quoted text: First")).toBeInTheDocument();
      expect(screen.getByLabelText("Quoted text: Later")).toBeInTheDocument();
      expect(document.querySelectorAll('[data-slot="quote-attachment"]')).toHaveLength(
        2
      );
    } finally {
      rect.mockRestore();
    }
  });

  it("quotes the selection with the Cmd+L shortcut and drops it on request", async () => {
    const user = userEvent.setup();
    const rect = vi
      .spyOn(Range.prototype, "getBoundingClientRect")
      .mockReturnValue(domRect(120, 200, 180, 20));

    try {
      renderConversation(
        <ConversationViewWithDraft
          actions={createActions()}
          state={state({
            messages: [
              message("msg_shortcut", "assistant", "圆橡皮，中间留出金属箍空隙。"),
            ],
          })}
        />
      );

      selectChatText(await screen.findByText("圆橡皮，中间留出金属箍空隙。"), 0, 3);
      await screen.findByRole("button", { name: "Add to chat" });

      fireEvent.keyDown(window, { key: "l", metaKey: true });

      const chip = await screen.findByLabelText("Quoted text: 圆橡皮");
      // A quote alone is enough to send, even with an empty draft.
      expect(screen.getByRole("button", { name: "Send message" })).toBeEnabled();

      await user.click(
        within(chip.closest('[data-slot="quote-attachment"]')!).getByRole("button", {
          name: "Remove 圆橡皮",
        })
      );

      expect(screen.queryByLabelText("Quoted text: 圆橡皮")).toBeNull();
      expect(screen.getByRole("button", { name: "Send message" })).toBeDisabled();
    } finally {
      rect.mockRestore();
    }
  });

  it("hands the quote bar in along the direction the selection was drawn", async () => {
    const rect = vi
      .spyOn(Range.prototype, "getBoundingClientRect")
      .mockReturnValue(domRect(120, 200, 180, 20));

    try {
      renderConversation(
        <ConversationViewWithDraft
          actions={createActions()}
          state={state({
            messages: [
              message("msg_direction", "assistant", "圆橡皮，中间留出金属箍空隙。"),
            ],
          })}
        />
      );

      const output = await screen.findByText("圆橡皮，中间留出金属箍空隙。");

      selectChatText(output, 0, 3);
      await waitFor(() =>
        expect(selectionActionBar()).toHaveAttribute("data-direction", "forward")
      );

      selectChatText(output, 0, 4, { backward: true });
      await waitFor(() =>
        expect(selectionActionBar()).toHaveAttribute("data-direction", "backward")
      );

      // A double-click selects a word without the pointer travelling, so the
      // bar must appear in place rather than sliding in from either side.
      selectChatText(output, 0, 5, { clickCount: 2 });
      await waitFor(() =>
        expect(selectionActionBar()).toHaveAttribute("data-direction", "none")
      );
    } finally {
      rect.mockRestore();
    }
  });

  it("keeps the quote bar when the drag overshoots past the message", async () => {
    const rect = vi
      .spyOn(Range.prototype, "getBoundingClientRect")
      .mockReturnValue(domRect(120, 200, 180, 20));

    try {
      renderConversation(
        <ConversationViewWithDraft
          actions={createActions()}
          state={state({
            messages: [
              message("msg_overshoot_a", "assistant", "圆橡皮，中间留出金属箍空隙。"),
              message("msg_overshoot_b", "user", "下一条消息。"),
            ],
          })}
        />
      );

      const output = await screen.findByText("圆橡皮，中间留出金属箍空隙。");
      const article = output.closest('[data-slot="chat-assistant-output"]')!;
      const textNode = output.firstChild!;

      // Drag down out of the message: the selection now ends past the article,
      // over content the reader cannot see themselves selecting.
      const range = document.createRange();
      range.setStart(textNode, 0);
      range.setEndAfter(article);
      const selection = window.getSelection();
      selection?.removeAllRanges();
      selection?.addRange(range);
      fireEvent.pointerUp(document);

      await waitFor(() => expect(selectionActionBar()).not.toBeNull());
      // The overshoot is clamped back to the message, so the highlight shows
      // exactly what the quote will carry.
      expect(window.getSelection()?.toString()).toBe("圆橡皮，中间留出金属箍空隙。");

      await userEvent
        .setup()
        .click(await screen.findByRole("button", { name: "Add to chat" }));
      expect(
        await screen.findByLabelText("Quoted text: 圆橡皮，中间留出金属箍空隙。")
      ).toBeInTheDocument();
    } finally {
      rect.mockRestore();
    }
  });

  it("does not offer the quote action for a selection outside chat messages", async () => {
    const rect = vi
      .spyOn(Range.prototype, "getBoundingClientRect")
      .mockReturnValue(domRect(120, 200, 180, 20));

    try {
      renderConversation(
        <ConversationViewWithDraft
          actions={createActions()}
          state={state({
            messages: [message("msg_outside", "assistant", "Agent reply text")],
          })}
        />
      );

      const heading = await screen.findByRole("heading", {
        name: "整理本周会议纪要为周报",
      });
      selectChatText(heading, 0, 3);

      await waitFor(() =>
        expect(screen.queryByRole("button", { name: "Add to chat" })).toBeNull()
      );
    } finally {
      rect.mockRestore();
    }
  });

  it("renders a sent quote as its own block ahead of the message bubble", async () => {
    renderConversation(
      <ConversationViewWithDraft
        actions={createActions()}
        state={state({
          messages: [
            message(
              "msg_quoted_send",
              "user",
              "Quoted from this conversation:\n> 圆橡皮\n\n这段是什么意思？"
            ),
          ],
        })}
      />
    );

    const quote = await screen.findByTestId("chat-message-quote");
    // Icon-only tile, matching the composer's staged quote chip: the text
    // lives in the hover card and on the trigger's label, not in the flow.
    expect(quote).not.toHaveTextContent("圆橡皮");
    expect(within(quote).getByLabelText("Quoted text: 圆橡皮")).toBeInTheDocument();

    const article = quote.closest('[data-slot="chat-user-output"]');
    expect(article?.firstElementChild).toBe(quote);

    const bubble = screen.getByTestId("chat-user-bubble-content");
    expect(bubble).toHaveTextContent("这段是什么意思？");
    expect(bubble.textContent).not.toContain("Quoted from this conversation:");
  });

  it("stacks a companioned user turn as images, quote, file pills, then bubble", async () => {
    renderConversation(
      <ConversationViewWithDraft
        actions={createActions()}
        state={state({
          messages: [
            message(
              "msg_companioned",
              "user",
              "Quoted from this conversation:\n> 参考截图\n\n请对齐设置页",
              {
                attachments: [
                  {
                    blockType: "image",
                    fileName: "screenshot.png",
                    mimeType: "image/png",
                    size: 1024,
                    title: "screenshot.png",
                  },
                  {
                    blockType: "file",
                    fileName: "Openai.pdf",
                    mimeType: "application/pdf",
                    size: 2048,
                    title: "Openai.pdf",
                  },
                ],
              }
            ),
          ],
        })}
      />
    );

    const quote = await screen.findByTestId("chat-message-quote");
    const article = quote.closest<HTMLElement>('[data-slot="chat-user-output"]');
    expect(article).not.toBeNull();
    const children = Array.from(article!.children) as HTMLElement[];

    const imageExtras = children[0]!;
    expect(imageExtras.className).toContain("comma-chat-block-extras");
    expect(imageExtras).toHaveAttribute("data-placement", "leading");
    expect(imageExtras.querySelector(".chat-panel-image-group")).not.toBeNull();
    expect(
      imageExtras.querySelector("[data-testid^='chat-attachment-pill-']")
    ).toBeNull();

    expect(children[1]).toBe(quote);

    const fileExtras = children[2]!;
    expect(fileExtras).toHaveAttribute("data-placement", "leading");
    // The file pill keeps its wire position (index 1) even though the image
    // renders in the leading section.
    expect(
      within(fileExtras).getByTestId("chat-attachment-pill-msg_companioned-1")
    ).toHaveTextContent("Openai.pdf");
    expect(fileExtras.querySelector(".chat-panel-image-group")).toBeNull();

    expect(children[3]!.querySelector(".comma-chat-user-bubble-slot")).not.toBeNull();
  });

  it("opens a text context menu with Copy on assistant output", async () => {
    const user = userEvent.setup();
    const actions = createActions();
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });

    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          messages: [message("msg_text_menu", "assistant", "Agent reply text")],
        })}
      />
    );

    const output = await screen.findByText("Agent reply text");
    const article = output.closest<HTMLElement>('[data-slot="chat-assistant-output"]');
    expect(article).not.toBeNull();
    const contextMenuEvent = new MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
      clientX: 120,
      clientY: 80,
    });
    expect(fireEvent(article!, contextMenuEvent)).toBe(false);
    expect(contextMenuEvent.defaultPrevented).toBe(true);

    const items = await screen.findAllByRole("menuitem");
    expect(items).toHaveLength(1);
    expect(items[0]).toHaveAccessibleName("Copy");
    expect(
      screen.queryByRole("menuitem", { name: "Copy message" })
    ).not.toBeInTheDocument();

    await user.click(screen.getByRole("menuitem", { name: "Copy" }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith("Agent reply text"));
  });

  it("copies the selected assistant text from the Copy menu", async () => {
    const user = userEvent.setup();
    const actions = createActions();
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });

    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          messages: [message("msg_text_selection", "assistant", "Agent reply text")],
        })}
      />
    );

    const output = await screen.findByText("Agent reply text");
    const textNode = output.firstChild;
    if (!textNode) throw new Error("expected assistant text node");
    const range = document.createRange();
    range.setStart(textNode, 0);
    range.setEnd(textNode, 5);
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);

    fireEvent(
      output,
      new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: 120,
        clientY: 80,
      })
    );
    await user.click(await screen.findByRole("menuitem", { name: "Copy" }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith("Agent"));
  });

  it("renders a user message's task mention as an InlineTask chip in the bubble", async () => {
    const actions = createActions();

    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          messages: [
            message(
              "msg_user_task_mention",
              "user",
              "Check [Fix login](comma:task/cnv1_menu) today"
            ),
          ],
        })}
      />
    );

    const output = await screen.findByTestId("chat-user-bubble-content");
    expect(output).toHaveTextContent("Check Fix login today");
    expect(output.textContent).not.toContain("comma:task");
    expect(within(output).getByTestId("chat-inline-task-cnv1_menu")).toHaveTextContent(
      "Fix login"
    );
  });

  it.each(["home", "route", "rail"] as const)(
    "opens user inline task mentions according to the %s surface",
    async (variant) => {
      const onOpenConversationRef = vi.fn();
      renderConversation(
        <ConversationViewWithDraft
          actions={createActions()}
          groupId="grp_1"
          onOpenConversationRef={onOpenConversationRef}
          state={state({
            messages: [
              message("msg_mention", "user", "Check [Fix login](comma:task/cnv1_menu)"),
            ],
          })}
          variant={variant}
          workspaceId="wsp_1"
        />
      );

      const task = await screen.findByRole("link", {
        name: "Open task: Fix login",
      });
      fireEvent.click(task);
      expect(onOpenConversationRef).toHaveBeenCalledWith({
        conversationId: "cnv1_menu",
        kind: "agent_task",
        title: "Fix login",
      });
      expect(task).toHaveAttribute("href", "/tasks/wsp_1/grp_1/cnv1_menu");
    }
  );

  it("opens a text context menu with Copy on user bubbles", async () => {
    const user = userEvent.setup();
    const actions = createActions();
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });

    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          messages: [message("msg_user_context", "user", "User prompt text")],
        })}
      />
    );

    const output = await screen.findByTestId("chat-user-bubble-content");
    const article = output.closest<HTMLElement>('[data-slot="chat-user-output"]');
    expect(article).not.toBeNull();
    const contextMenuEvent = new MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
      clientX: 120,
      clientY: 80,
    });
    expect(fireEvent(output, contextMenuEvent)).toBe(false);
    expect(contextMenuEvent.defaultPrevented).toBe(true);

    const items = await screen.findAllByRole("menuitem");
    expect(items).toHaveLength(1);
    expect(items[0]).toHaveAccessibleName("Copy");

    await user.click(screen.getByRole("menuitem", { name: "Copy" }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith("User prompt text"));
  });

  it("copies the selected user bubble text from the Copy menu", async () => {
    const user = userEvent.setup();
    const actions = createActions();
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });

    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          messages: [message("msg_user_selection", "user", "User prompt text")],
        })}
      />
    );

    const output = await screen.findByTestId("chat-user-bubble-content");
    const textNode = output.firstChild;
    if (!textNode) throw new Error("expected user bubble text node");
    const range = document.createRange();
    range.setStart(textNode, 0);
    range.setEnd(textNode, 4);
    const selection = window.getSelection();
    selection?.removeAllRanges();
    selection?.addRange(range);

    fireEvent(
      output,
      new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: 120,
        clientY: 80,
      })
    );
    await user.click(await screen.findByRole("menuitem", { name: "Copy" }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith("User"));
  });

  it("copies the visible user bubble body without attachment protocol text", async () => {
    const user = userEvent.setup();
    const actions = createActions();
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });
    const text = composeMessageWithAttachments("请看这些文件", [
      { name: "report.txt", path: "/uploads/1-report.txt" },
    ]);

    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          messages: [message("msg_file_copy", "user", text)],
        })}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const output = await screen.findByTestId("chat-user-bubble-content");
    fireEvent(
      output,
      new MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: 120,
        clientY: 80,
      })
    );
    await user.click(await screen.findByRole("menuitem", { name: "Copy" }));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith("请看这些文件"));
  });

  it("parses user attached-files blocks into chips without showing protocol text", async () => {
    const actions = createActions();
    const text = composeMessageWithAttachments("请看这些文件", [
      { name: "report.txt", path: "/uploads/1-report.txt" },
    ]);

    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          messages: [message("msg_file", "user", text)],
        })}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(await screen.findByText("请看这些文件")).toBeInTheDocument();
    expect(screen.queryByText("Attached files in your workspace:")).toBeNull();
    expect(screen.getByTestId("chat-attachment-pill-msg_file-0")).toHaveTextContent(
      "report.txt"
    );
  });

  it("merges attached-files text chips while deduplicating structured equivalents", async () => {
    const actions = createActions();
    const text = composeMessageWithAttachments("请看这些文件", [
      { name: "structured.pdf", path: "/uploads/1-structured.pdf" },
      { name: "text-block.txt", path: "/uploads/1-text-block.txt" },
    ]);

    renderConversation(
      <ConversationViewWithDraft
        actions={actions}
        state={state({
          messages: [
            message("msg_file", "user", text, {
              attachments: [
                {
                  blockType: "file",
                  fileName: "structured.pdf",
                  mimeType: "application/pdf",
                  size: 100,
                  title: "structured.pdf",
                },
              ],
            }),
          ],
        })}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(await screen.findByText("请看这些文件")).toBeInTheDocument();
    expect(screen.getByTestId("chat-attachment-pill-msg_file-0")).toHaveTextContent(
      "structured.pdf"
    );
    expect(screen.getByTestId("chat-attachment-pill-msg_file-1")).toHaveTextContent(
      "text-block.txt"
    );
    expect(screen.getAllByText("structured.pdf")).toHaveLength(1);
  });
});

describe("ConversationThread", () => {
  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("shows a real local-image thumbnail in the Composer and releases it when removed", async () => {
    const localFileRef = `lfi1_${"d".repeat(43)}`;
    const release = vi.fn();
    const previewLocalFile = vi.fn(async () => ({
      release,
      url: "blob:draft-image-preview",
    }));
    const draftAttachment = {
      error: undefined,
      id: localFileRef,
      isImage: true,
      name: "draft-photo.png",
      path: undefined,
      size: 456,
      status: "uploaded" as const,
    };
    const actions = {
      ...createActions(),
      previewLocalFile,
    };
    const rendered = renderStatefulConversation(
      state({ draftAttachments: [draftAttachment] }),
      actions
    );

    const thumbnail = await screen.findByRole("img", { name: "draft-photo.png" });
    await waitFor(() =>
      expect(thumbnail).toHaveAttribute("src", "blob:draft-image-preview")
    );
    expect(previewLocalFile).toHaveBeenCalledWith(
      localFileRef,
      expect.any(AbortSignal)
    );
    expect(release).not.toHaveBeenCalled();

    act(() => rendered.setState(state({ draftAttachments: [] })));
    await waitFor(() => expect(release).toHaveBeenCalledOnce());
    expect(screen.queryByRole("img", { name: "draft-photo.png" })).toBeNull();
  });

  it("shows an uploaded workspace-image thumbnail in the Composer", async () => {
    const workspacePath = `/uploads/${"B".repeat(22)}-draft-photo.png`;
    const previewLocalFile = vi.fn(async () => ({
      release: vi.fn(),
      url: "blob:uploaded-draft-image-preview",
    }));
    renderStatefulConversation(
      state({
        draftAttachments: [
          {
            error: undefined,
            id: "native-uploaded-image",
            isImage: true,
            name: "draft-photo.png",
            path: workspacePath,
            size: 456,
            status: "uploaded",
          },
        ],
      }),
      { ...createActions(), previewLocalFile }
    );

    expect(await screen.findByRole("img", { name: "draft-photo.png" })).toHaveAttribute(
      "src",
      "blob:uploaded-draft-image-preview"
    );
    expect(previewLocalFile).toHaveBeenCalledWith(
      workspacePath,
      expect.any(AbortSignal)
    );
  });

  it("releases a Composer preview that resolves after its attachment unmounts", async () => {
    const localFileRef = `lfi1_${"l".repeat(43)}`;
    const release = vi.fn();
    let resolvePreview:
      | ((preview: { release(): void; url: string }) => void)
      | undefined;
    let previewSignal: AbortSignal | undefined;
    const previewLocalFile = vi.fn(
      (_previewRef: ChatImagePreviewRef, signal?: AbortSignal) => {
        previewSignal = signal;
        return new Promise<{ release(): void; url: string }>((resolve) => {
          resolvePreview = resolve;
        });
      }
    );
    const rendered = render(
      <Composer
        draftSource={fixedDraftSource("")}
        draftAttachments={[
          {
            error: undefined,
            id: localFileRef,
            isImage: true,
            name: "late-photo.png",
            path: undefined,
            size: 456,
            status: "uploaded",
          },
        ]}
        onDraftChange={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onSend={() => {}}
        submitDisabled={false}
      />
    );

    await waitFor(() =>
      expect(previewLocalFile).toHaveBeenCalledWith(
        localFileRef,
        expect.any(AbortSignal)
      )
    );
    rendered.unmount();
    expect(previewSignal?.aborted).toBe(true);
    await act(async () => {
      resolvePreview?.({ release, url: "blob:late-draft-preview" });
      await Promise.resolve();
    });
    expect(release).toHaveBeenCalledOnce();
  });

  it("keeps the image attachment shape when a Composer preview is unavailable", async () => {
    const localFileRef = `lfi1_${"u".repeat(43)}`;
    render(
      <Composer
        draftSource={fixedDraftSource("")}
        draftAttachments={[
          {
            error: undefined,
            id: localFileRef,
            isImage: true,
            name: "unavailable-photo.png",
            path: undefined,
            size: 456,
            status: "uploaded",
          },
        ]}
        onDraftChange={() => {}}
        onPreviewLocalFile={async () => undefined}
        onSend={() => {}}
        submitDisabled={false}
      />
    );

    // Still an image tile, showing the image glyph rather than a stand-in
    // picture, and never demoted to a file chip.
    const tile = await screen.findByTestId("image-attachment");
    await waitFor(() =>
      expect(tile.querySelector('[data-state="ready"]')).not.toBeNull()
    );
    expect(tile.querySelector('[data-slot="image-attachment-glyph"]')).not.toBeNull();
    expect(screen.queryByRole("img", { name: "unavailable-photo.png" })).toBeNull();
    expect(document.querySelector('[data-slot="file-attachment"]')).toBeNull();
  });

  it("hands a Composer preview to the newly sent visible message before retirement", async () => {
    installIntersectionObserverHarness();
    const originalGetBoundingClientRect = Element.prototype.getBoundingClientRect;
    const geometry = vi
      .spyOn(Element.prototype, "getBoundingClientRect")
      .mockImplementation(function (this: Element) {
        if (this.getAttribute("data-slot") === "scroll-area-viewport") {
          return sizedElementRect(0, 480);
        }
        if (this.classList.contains("comma-chat-attachments")) {
          return sizedElementRect(120, 100);
        }
        return originalGetBoundingClientRect.call(this);
      });
    const localFileRef = `lfi1_${"h".repeat(43)}`;
    const load = vi.fn(async () => Uint8Array.of(1, 2, 3));
    const createObjectURL = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:composer-to-message-handoff");
    const revokeObjectURL = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => {});
    const cache = new LocalFilePreviewCache({ load });
    const actions = {
      ...createActions(),
      previewLocalFile: (ref: ChatImagePreviewRef, signal?: AbortSignal) =>
        cache.acquire(ref, signal),
    };
    const draftAttachment = {
      error: undefined,
      id: localFileRef,
      isImage: true,
      name: "handoff-photo.png",
      path: undefined,
      size: 456,
      status: "uploaded" as const,
    };
    const rendered = renderStatefulConversation(
      state({ draftAttachments: [draftAttachment] }),
      actions
    );

    expect(
      await screen.findByRole("img", { name: "handoff-photo.png" })
    ).toHaveAttribute("src", "blob:composer-to-message-handoff");

    act(() => {
      rendered.setState(
        state({
          draftAttachments: [],
          messages: [
            message("msg_handoff_image", "user", "", {
              attachments: [
                {
                  blockType: "image",
                  fileName: "handoff-photo.png",
                  localFileRef,
                  mimeType: "image/png",
                  size: 456,
                  title: undefined,
                },
              ],
            }),
          ],
        })
      );
    });

    await waitForNamedImageSrc("handoff-photo.png", "blob:composer-to-message-handoff");
    expect(load).toHaveBeenCalledOnce();
    expect(createObjectURL).toHaveBeenCalledOnce();
    expect(revokeObjectURL).not.toHaveBeenCalled();

    rendered.unmount();
    await act(async () => Promise.resolve());
    expect(revokeObjectURL).toHaveBeenCalledOnce();
    cache.dispose();
    geometry.mockRestore();
    createObjectURL.mockRestore();
    revokeObjectURL.mockRestore();
  });

  it.each([1, 3])(
    "renders %i sent local images through the existing flat image-group layout",
    async (count) => {
      const attachments = Array.from({ length: count }, (_, index) =>
        localImageAttachment(index)
      );
      const previewLocalFile = vi.fn(async (localFileRef: ChatImagePreviewRef) => ({
        release: vi.fn(),
        url: `blob:sent-${localFileRef}`,
      }));
      const rendered = render(
        <ConversationThread
          messages={[message(`msg_${count}_images`, "user", "", { attachments })]}
          onDiscard={() => {}}
          onPreviewLocalFile={previewLocalFile}
          onRetry={() => {}}
          groupId="grp_1"
          workspaceId="wsp_1"
        />
      );

      const group = await waitFor(() => {
        const element = rendered.container.querySelector<HTMLElement>(
          ".chat-panel-image-group"
        );
        expect(element).not.toBeNull();
        return element!;
      });
      expect(group.querySelectorAll(".chat-panel-image-group-card")).toHaveLength(
        count
      );
      expect(group.querySelector("[data-stack-pos]")).toBeNull();
      expect(group.querySelector("[data-expanded='true']")).not.toBeNull();
      for (const attachment of attachments) {
        await waitForNamedImageSrc(
          attachment.fileName!,
          `blob:sent-${attachment.localFileRef}`
        );
        expect(previewLocalFile).toHaveBeenCalledWith(
          attachment.localFileRef,
          expect.any(AbortSignal)
        );
      }
    }
  );

  it("renders a sent uploaded image through the image-group layout", async () => {
    const workspacePath = `/uploads/${"A".repeat(22)}-opaque-photo.png`;
    const previewLocalFile = vi.fn(async () => ({
      release: vi.fn(),
      url: "blob:uploaded-image-preview",
    }));
    const text = composeMessageWithAttachments("请看图片", [
      { name: "photo.png", path: workspacePath },
    ]);
    const rendered = render(
      <ConversationThread
        messages={[message("msg_uploaded_image", "user", text)]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    await waitForNamedImageSrc("photo.png", "blob:uploaded-image-preview");
    expect(previewLocalFile).toHaveBeenCalledWith(
      workspacePath,
      expect.any(AbortSignal)
    );
    expect(
      rendered.container.querySelector(
        '[data-testid="chat-attachment-pill-msg_uploaded_image-0"]'
      )
    ).toBeNull();
    expect(
      rendered.container.querySelector(
        '[data-testid="chat-attachment-image-msg_uploaded_image-0"]'
      )
    ).toBeNull();
  });

  it("renders an Agent image by resolving the blob reference selected by the client", async () => {
    const blobRef = {
      hash: "b".repeat(64),
      kind: "blob" as const,
      size: 4,
      uuid: "a".repeat(32),
    };
    const previewLocalFile = vi.fn(async () => ({
      release: vi.fn(),
      url: "blob:agent-image-preview",
    }));

    render(
      <ConversationThread
        messages={[
          message("msg_agent_image", "assistant", "", {
            attachments: [
              {
                agentId: "agt1_image_author",
                blockType: "image",
                blobRef,
                fileName: "capture.png",
                mimeType: "image/png",
                size: 4,
                title: undefined,
                workspacePath: "/artifacts/capture.png",
              },
            ],
          }),
        ]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    await waitForNamedImageSrc("capture.png", "blob:agent-image-preview");
    expect(previewLocalFile).toHaveBeenCalledWith(
      {
        agentId: "agt1_image_author",
        blobRef,
        fileName: "capture.png",
        kind: "agent-blob",
        mediaType: "image/png",
      },
      expect.any(AbortSignal)
    );
  });

  it("uses the attached-files workspace path when the canonical image has none", async () => {
    const workspacePath = `/uploads/${"C".repeat(22)}-canonical-photo.png`;
    const previewLocalFile = vi.fn(async () => ({
      release: vi.fn(),
      url: "blob:canonical-workspace-preview",
    }));
    const text = composeMessageWithAttachments("请看图片", [
      { name: "photo.png", path: workspacePath },
    ]);
    render(
      <ConversationThread
        messages={[
          message("msg_canonical_image_path", "user", text, {
            attachments: [
              {
                blockType: "image",
                fileName: "photo.png",
                mimeType: "image/png",
                size: 456,
                title: "photo.png",
              },
            ],
          }),
        ]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    await waitForNamedImageSrc("photo.png", "blob:canonical-workspace-preview");
    expect(previewLocalFile).toHaveBeenCalledWith(
      workspacePath,
      expect.any(AbortSignal)
    );
  });

  it("keeps an uploaded image beside a canonical local file after send and reload", async () => {
    const workspacePath = `/uploads/${"B".repeat(22)}-remote-photo.png`;
    const localFileRef = `lfi1_${"m".repeat(43)}`;
    const previewLocalFile = vi.fn(async () => ({
      release: vi.fn(),
      url: "blob:mixed-upload-preview",
    }));
    const mixedMessage = () =>
      message(
        "msg_mixed_upload_local",
        "user",
        composeMessageWithAttachments("", [
          { name: "remote-photo.png", path: workspacePath },
        ]),
        {
          attachments: [
            {
              blockType: "file",
              fileName: "local-notes.txt",
              localFileRef,
              mimeType: "text/plain",
              size: 321,
              title: "local-notes.txt",
            },
          ],
        }
      );
    const rendered = render(
      <ConversationThread
        messages={[mixedMessage()]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const expectMixedAttachments = async () => {
      await waitForNamedImageSrc("remote-photo.png", "blob:mixed-upload-preview");
      expect(
        within(rendered.container).getByTestId(
          "chat-attachment-pill-msg_mixed_upload_local-0"
        )
      ).toHaveTextContent("local-notes.txt");
    };

    await expectMixedAttachments();
    expect(previewLocalFile).toHaveBeenCalledWith(
      workspacePath,
      expect.any(AbortSignal)
    );

    rendered.rerender(
      <ConversationThread
        messages={[]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );
    rendered.rerender(
      <ConversationThread
        messages={[mixedMessage()]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    await expectMixedAttachments();
    expect(previewLocalFile).toHaveBeenCalledTimes(2);
  });

  it("renders four sent local images through the existing collapsed image-group deck", async () => {
    const attachments = Array.from({ length: 4 }, (_, index) =>
      localImageAttachment(index)
    );
    const previewLocalFile = vi.fn(async (localFileRef: ChatImagePreviewRef) => ({
      release: vi.fn(),
      url: `blob:stack-${localFileRef}`,
    }));
    const rendered = render(
      <ConversationThread
        messages={[message("msg_4_images", "user", "", { attachments })]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const toggle = await screen.findByRole("button", { name: "4 Images" });
    expect(toggle).toHaveAttribute("aria-expanded", "false");
    const group = rendered.container.querySelector(".chat-panel-image-group");
    expect(group).not.toBeNull();
    const cards = group!.querySelectorAll<HTMLElement>(".chat-panel-image-group-card");
    expect(cards).toHaveLength(4);
    expect([...cards].filter((card) => card.dataset.stackPos === "0")).toHaveLength(1);
    await waitFor(() => expect(previewLocalFile).toHaveBeenCalledTimes(4));
  });

  it("keeps more than three sent images in the stacked image-group before previews resolve", async () => {
    const attachments = Array.from({ length: 5 }, (_, index) =>
      localImageAttachment(index)
    );
    const rendered = render(
      <ConversationThread
        messages={[message("msg_5_placeholder_images", "user", "", { attachments })]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    await waitFor(() =>
      expect(
        rendered.container.querySelector(".chat-panel-image-group-toggle-text")
      ).toHaveTextContent("5")
    );
    const group = rendered.container.querySelector(".chat-panel-image-group");
    expect(group).not.toBeNull();
    expect(group).toHaveAttribute("data-comma-image-group-placeholder");
    expect(group!.querySelectorAll(".chat-panel-image-group-card")).toHaveLength(1);
    expect(
      screen.queryByTestId("chat-attachment-image-msg_5_placeholder_images-0")
    ).toBeNull();
  });

  it("holds one full-count placeholder until every preview in a multi-image message settles", async () => {
    const attachments = Array.from({ length: 3 }, (_, index) =>
      localImageAttachment(index)
    );
    const resolvers = new Map<
      string,
      (preview: { release(): void; url: string }) => void
    >();
    const previewLocalFile = vi.fn(
      (previewRef: ChatImagePreviewRef) =>
        new Promise<{ release(): void; url: string }>((resolve) => {
          resolvers.set(previewRef as string, resolve);
        })
    );
    const rendered = render(
      <ConversationThread
        messages={[message("msg_settling_images", "user", "", { attachments })]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );
    const placeholder = () =>
      rendered.container.querySelector("[data-comma-image-group-placeholder]");
    const groups = () => rendered.container.querySelectorAll(".chat-panel-image-group");

    await waitFor(() => expect(previewLocalFile).toHaveBeenCalledTimes(3));
    expect(groups()).toHaveLength(1);
    expect(
      placeholder()!.querySelectorAll(".chat-panel-image-group-card")
    ).toHaveLength(3);

    // The first preview landing alone must not open a one-card group beside a
    // two-card placeholder: the message keeps its single reserved footprint.
    await act(async () => {
      resolvers.get(attachments[0]!.localFileRef!)!({
        release: vi.fn(),
        url: "blob:settling-1",
      });
      await Promise.resolve();
    });
    expect(groups()).toHaveLength(1);
    expect(placeholder()).not.toBeNull();
    expect(
      placeholder()!.querySelectorAll(".chat-panel-image-group-card")
    ).toHaveLength(3);
    expect(screen.queryByRole("img", { name: attachments[0]!.fileName! })).toBeNull();

    await act(async () => {
      resolvers.get(attachments[1]!.localFileRef!)!({
        release: vi.fn(),
        url: "blob:settling-2",
      });
      resolvers.get(attachments[2]!.localFileRef!)!({
        release: vi.fn(),
        url: "blob:settling-3",
      });
      await Promise.resolve();
    });
    await waitForNamedImageSrc(attachments[2]!.fileName!, "blob:settling-3");
    expect(placeholder()).toBeNull();
    expect(groups()).toHaveLength(1);
    expect(groups()[0]!.querySelectorAll(".chat-panel-image-group-card")).toHaveLength(
      3
    );
  });

  it("keeps the deck's reserved geometry when one preview fails before the others settle", async () => {
    const observer = installIntersectionObserverHarness();
    const attachments = Array.from({ length: 4 }, (_, index) =>
      localImageAttachment(index)
    );
    const resolvers = new Map<
      string,
      (preview: { release(): void; url: string } | undefined) => void
    >();
    const previewLocalFile = vi.fn(
      (previewRef: ChatImagePreviewRef) =>
        new Promise<{ release(): void; url: string } | undefined>((resolve) => {
          resolvers.set(previewRef as string, resolve);
        })
    );
    const rendered = render(
      <ConversationThread
        messages={[message("msg_early_failure", "user", "", { attachments })]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );
    const observed = observer.firstObserved();
    const placeholder = () =>
      rendered.container.querySelector("[data-comma-image-group-placeholder]");
    const settle = async (index: number, url: string | undefined) => {
      await act(async () => {
        resolvers.get(attachments[index]!.localFileRef!)!(
          url ? { release: vi.fn(), url } : undefined
        );
        await Promise.resolve();
      });
    };

    observer.notify("inner", observed, true);
    await waitFor(() => expect(previewLocalFile).toHaveBeenCalledTimes(4));

    // The second image fails first. The placeholder must stay the four-image
    // collapsed deck it started as, with no fallback card yet.
    await settle(1, undefined);
    expect(placeholder()).not.toBeNull();
    expect(
      placeholder()!.querySelector(".chat-panel-image-group-toggle-text")
    ).toHaveTextContent("4");
    expect(placeholder()!.querySelector("[data-expanded]")).toHaveAttribute(
      "data-expanded",
      "false"
    );
    expect(screen.queryByTestId("chat-attachment-file-msg_early_failure-1")).toBeNull();

    await settle(0, "blob:early-1");
    await settle(2, "blob:early-3");
    expect(placeholder()).not.toBeNull();
    expect(screen.queryByTestId("chat-attachment-file-msg_early_failure-1")).toBeNull();

    // The last preview settles: three images and the fallback reveal together.
    await settle(3, "blob:early-4");
    await waitForNamedImageSrc(attachments[3]!.fileName!, "blob:early-4");
    expect(placeholder()).toBeNull();
    expect(
      rendered.container.querySelectorAll(".chat-panel-image-group-card")
    ).toHaveLength(3);
    expect(
      screen.getByTestId("chat-attachment-file-msg_early_failure-1")
    ).toBeInTheDocument();

    // Scrolling keeps both the revealed images and the terminal fallback.
    observer.notify("outer", observed, false);
    expect(placeholder()).toBeNull();
    expect(
      rendered.container.querySelectorAll(".chat-panel-image-group-card")
    ).toHaveLength(3);
    expect(
      screen.getByTestId("chat-attachment-file-msg_early_failure-1")
    ).toBeInTheDocument();

    observer.notify("inner", observed, true);
    expect(previewLocalFile).toHaveBeenCalledTimes(4);
  });

  it("reveals the settled images once a preview outlives the settle deadline", async () => {
    vi.useFakeTimers();
    const attachments = Array.from({ length: 3 }, (_, index) =>
      localImageAttachment(index)
    );
    const resolvers = new Map<
      string,
      (preview: { release(): void; url: string } | undefined) => void
    >();
    const previewLocalFile = vi.fn(
      (previewRef: ChatImagePreviewRef) =>
        new Promise<{ release(): void; url: string } | undefined>((resolve) => {
          resolvers.set(previewRef as string, resolve);
        })
    );
    const rendered = render(
      <ConversationThread
        messages={[message("msg_stalled_preview", "user", "", { attachments })]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );
    const placeholder = () =>
      rendered.container.querySelector("[data-comma-image-group-placeholder]");

    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    expect(previewLocalFile).toHaveBeenCalledTimes(3);
    await act(async () => {
      resolvers.get(attachments[0]!.localFileRef!)!({
        release: vi.fn(),
        url: "blob:stall-1",
      });
      resolvers.get(attachments[2]!.localFileRef!)!({
        release: vi.fn(),
        url: "blob:stall-3",
      });
      await vi.advanceTimersByTimeAsync(0);
    });

    // The middle preview never answers. Just short of the deadline the message
    // is still one reserved three-card placeholder.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(19_999);
    });
    expect(placeholder()).not.toBeNull();
    expect(
      placeholder()!.querySelectorAll(".chat-panel-image-group-card")
    ).toHaveLength(3);
    expect(screen.queryByRole("img", { name: attachments[0]!.fileName! })).toBeNull();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(1);
    });
    expect(placeholder()).toBeNull();
    expect(
      screen.getByRole("img", { name: attachments[0]!.fileName! })
    ).toHaveAttribute("src", "blob:stall-1");
    expect(
      screen.getByRole("img", { name: attachments[2]!.fileName! })
    ).toHaveAttribute("src", "blob:stall-3");
    expect(
      screen.getByTestId("chat-attachment-file-msg_stalled_preview-1")
    ).toBeInTheDocument();
    expect(previewLocalFile).toHaveBeenCalledTimes(3);
  });

  it("brings a re-entering deck back in the layout the reader left it in", async () => {
    const observer = installIntersectionObserverHarness();
    const attachments = Array.from({ length: 4 }, (_, index) =>
      localImageAttachment(index)
    );
    let visit = 1;
    const previewLocalFile = vi.fn(async (previewRef: ChatImagePreviewRef) => ({
      release: vi.fn(),
      url: `blob:deck-visit-${visit}-${previewRef}`,
    }));
    const rendered = render(
      <ConversationThread
        messages={[message("msg_reentering_deck", "user", "", { attachments })]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );
    const observed = observer.firstObserved();
    const placeholder = () =>
      rendered.container.querySelector("[data-comma-image-group-placeholder]");

    observer.notify("inner", observed, true);
    await waitForNamedImageSrc(
      attachments[0]!.fileName!,
      `blob:deck-visit-1-${attachments[0]!.localFileRef}`
    );
    const toggle = screen.getByRole("button", { name: "4 Images" });
    expect(toggle).toHaveAttribute("aria-expanded", "false");
    fireEvent.click(toggle);
    expect(screen.getByRole("button", { name: "Hide" })).toHaveAttribute(
      "aria-expanded",
      "true"
    );

    // Keep the same expanded deck and sources across viewport re-entry.
    observer.notify("outer", observed, false);
    expect(placeholder()).toBeNull();
    expect(
      rendered.container.querySelector(".chat-panel-image-group-cards")
    ).toHaveAttribute("data-expanded", "true");
    expect(
      rendered.container.querySelectorAll(".chat-panel-image-group-card")
    ).toHaveLength(4);

    visit = 2;
    observer.notify("inner", observed, true);
    await waitForNamedImageSrc(
      attachments[3]!.fileName!,
      `blob:deck-visit-1-${attachments[3]!.localFileRef}`
    );
    expect(placeholder()).toBeNull();
    expect(screen.getByRole("button", { name: "Hide" })).toHaveAttribute(
      "aria-expanded",
      "true"
    );
  });

  it("does not start image preview loads while the thread is still pinned from the top", async () => {
    const observer = installIntersectionObserverHarness();
    const originalGetBoundingClientRect = Element.prototype.getBoundingClientRect;
    const geometry = vi
      .spyOn(Element.prototype, "getBoundingClientRect")
      .mockImplementation(function (this: Element) {
        if (this.getAttribute("data-slot") === "scroll-area-viewport") {
          return sizedElementRect(0, 480);
        }
        if (this.classList.contains("comma-chat-attachments")) {
          return sizedElementRect(24, 100);
        }
        return originalGetBoundingClientRect.call(this);
      });
    const scrollHeight = vi
      .spyOn(HTMLElement.prototype, "scrollHeight", "get")
      .mockImplementation(function (this: HTMLElement) {
        return this.getAttribute("data-slot") === "scroll-area-viewport" ? 2400 : 0;
      });
    const clientHeight = vi
      .spyOn(HTMLElement.prototype, "clientHeight", "get")
      .mockImplementation(function (this: HTMLElement) {
        return this.getAttribute("data-slot") === "scroll-area-viewport" ? 480 : 0;
      });
    const scrollTop = vi
      .spyOn(HTMLElement.prototype, "scrollTop", "get")
      .mockReturnValue(0);
    const attachment = localImageAttachment(0);
    const previewLocalFile = vi.fn(async () => ({
      release: vi.fn(),
      url: "blob:should-wait-for-bottom-pin",
    }));

    try {
      const rendered = render(
        <ConversationThread
          messages={[
            message("msg_top_pin_image", "user", "", { attachments: [attachment] }),
            message("msg_latest_text", "user", "latest turn"),
          ]}
          onDiscard={() => {}}
          onPreviewLocalFile={previewLocalFile}
          onRetry={() => {}}
          groupId="grp_1"
          workspaceId="wsp_1"
        />
      );

      expect(observer.firstObserved()).toBeTruthy();
      expect(previewLocalFile).not.toHaveBeenCalled();
      expect(
        rendered.container.querySelector("[data-comma-image-group-placeholder]")
      ).not.toBeNull();

      scrollTop.mockReturnValue(1920);
      observer.notify("inner", observer.firstObserved(), true);
      await waitForNamedImageSrc(
        attachment.fileName!,
        "blob:should-wait-for-bottom-pin"
      );
    } finally {
      geometry.mockRestore();
      scrollHeight.mockRestore();
      clientHeight.mockRestore();
      scrollTop.mockRestore();
    }
  });

  it("loads a current-turn image when that overflowing turn is intentionally anchored at scrollTop zero", async () => {
    installIntersectionObserverHarness();
    const originalGetBoundingClientRect = Element.prototype.getBoundingClientRect;
    const geometry = vi
      .spyOn(Element.prototype, "getBoundingClientRect")
      .mockImplementation(function (this: Element) {
        if (this.getAttribute("data-slot") === "scroll-area-viewport") {
          return sizedElementRect(0, 480);
        }
        if (this.classList.contains("comma-chat-attachments")) {
          return sizedElementRect(24, 100);
        }
        return originalGetBoundingClientRect.call(this);
      });
    const scrollHeight = vi
      .spyOn(HTMLElement.prototype, "scrollHeight", "get")
      .mockImplementation(function (this: HTMLElement) {
        return this.getAttribute("data-slot") === "scroll-area-viewport" ? 2400 : 0;
      });
    const clientHeight = vi
      .spyOn(HTMLElement.prototype, "clientHeight", "get")
      .mockImplementation(function (this: HTMLElement) {
        return this.getAttribute("data-slot") === "scroll-area-viewport" ? 480 : 0;
      });
    const scrollTop = vi
      .spyOn(HTMLElement.prototype, "scrollTop", "get")
      .mockReturnValue(0);
    const attachment = localImageAttachment(0);
    const previewLocalFile = vi.fn(async () => ({
      release: vi.fn(),
      url: "blob:current-turn-at-zero",
    }));

    try {
      render(
        <ConversationThread
          messages={[
            message("msg_current_turn_image", "user", "", {
              attachments: [attachment],
            }),
          ]}
          onDiscard={() => {}}
          onPreviewLocalFile={previewLocalFile}
          onRetry={() => {}}
          groupId="grp_1"
          workspaceId="wsp_1"
        />
      );

      await waitForNamedImageSrc(attachment.fileName!, "blob:current-turn-at-zero");
      expect(previewLocalFile).toHaveBeenCalledOnce();
    } finally {
      geometry.mockRestore();
      scrollHeight.mockRestore();
      clientHeight.mockRestore();
      scrollTop.mockRestore();
    }
  });

  it("never paints a fake thumbnail for an unavailable image", async () => {
    const ready = localImageAttachment(0);
    const unavailable = localImageAttachment(1);
    const file = {
      blockType: "file" as const,
      fileName: "notes.pdf",
      mimeType: "application/pdf",
      size: 789,
      title: undefined,
    };
    const previewLocalFile = vi.fn(async (localFileRef: ChatImagePreviewRef) =>
      localFileRef === ready.localFileRef
        ? { release: vi.fn(), url: "blob:ready-local-image" }
        : undefined
    );
    const rendered = render(
      <ConversationThread
        messages={[
          message("msg_mixed_images", "user", "", {
            attachments: [ready, unavailable, file],
          }),
        ]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    await waitForNamedImageSrc(ready.fileName!, "blob:ready-local-image");
    await waitFor(() => {
      const groups = rendered.container.querySelectorAll(".chat-panel-image-group");
      expect(groups).toHaveLength(1);
      expect(groups[0]!.querySelectorAll(".chat-panel-image-group-card")).toHaveLength(
        1
      );
    });
    expect(screen.queryByRole("img", { name: unavailable.fileName! })).toBeNull();
    expect(screen.getByText(unavailable.fileName!)).toBeInTheDocument();
    expect(
      screen.getByTestId("chat-attachment-pill-msg_mixed_images-2")
    ).toHaveTextContent("notes.pdf");
  });

  it("keeps the same image node and lease across repeated viewport exits until unmount", async () => {
    const observer = installIntersectionObserverHarness();
    const attachment = localImageAttachment(0);
    const firstRelease = vi.fn();
    const secondRelease = vi.fn();
    const previewLocalFile = vi
      .fn<
        (
          previewRef: ChatImagePreviewRef,
          signal?: AbortSignal
        ) => Promise<{ release(): void; url: string } | undefined>
      >()
      .mockResolvedValueOnce({
        release: firstRelease,
        url: "blob:visible-in-retention-band",
      })
      .mockResolvedValueOnce({
        release: secondRelease,
        url: "blob:visible-after-band-reentry",
      });
    const rendered = render(
      <ConversationThread
        messages={[
          message("msg_hysteresis_image", "user", "", {
            attachments: [attachment],
          }),
        ]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const observed = observer.firstObserved();
    observer.notify("inner", observed, true);
    await waitForNamedImageSrc(attachment.fileName!, "blob:visible-in-retention-band");

    observer.notify("inner", observed, false);
    expect(firstRelease).not.toHaveBeenCalled();
    expect(screen.getByRole("img", { name: attachment.fileName! })).toHaveAttribute(
      "src",
      "blob:visible-in-retention-band"
    );

    const image = screen.getByRole("img", { name: attachment.fileName! });
    for (let visit = 0; visit < 3; visit += 1) {
      observer.notify("outer", observed, false);
      await act(async () => {
        await Promise.resolve();
      });
      expect(previewLocalFile.mock.calls[0]?.[1]?.aborted).toBe(false);
      expect(firstRelease).not.toHaveBeenCalled();
      expect(
        rendered.container.querySelector("[data-comma-image-group-placeholder]")
      ).toBeNull();
      expect(screen.getByRole("img", { name: attachment.fileName! })).toBe(image);
      observer.notify("inner", observed, true);
      expect(screen.getByRole("img", { name: attachment.fileName! })).toBe(image);
    }
    expect(previewLocalFile).toHaveBeenCalledOnce();
    rendered.unmount();
    expect(firstRelease).toHaveBeenCalledOnce();
    expect(secondRelease).not.toHaveBeenCalled();
  });

  it("keeps image preview leases while a paused overlay hides the chat surface", async () => {
    const observer = installIntersectionObserverHarness();
    const attachment = localImageAttachment(0);
    const firstRelease = vi.fn();
    const secondRelease = vi.fn();
    const previewLocalFile = vi
      .fn<
        (
          previewRef: ChatImagePreviewRef,
          signal?: AbortSignal
        ) => Promise<{ release(): void; url: string } | undefined>
      >()
      .mockResolvedValueOnce({
        release: firstRelease,
        url: "blob:visible-before-overlay",
      })
      .mockResolvedValueOnce({
        release: secondRelease,
        url: "blob:should-not-reload-while-paused",
      });
    const thread = (
      <ConversationThread
        messages={[
          message("msg_paused_surface_image", "user", "", {
            attachments: [attachment],
          }),
        ]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );
    const rendered = render(<div>{thread}</div>);

    const observed = observer.firstObserved();
    observer.notify("inner", observed, true);
    await waitForNamedImageSrc(attachment.fileName!, "blob:visible-before-overlay");

    rendered.rerender(<div data-comma-surface-paused="true">{thread}</div>);
    observer.notify("inner", observed, false);
    observer.notify("outer", observed, false);

    expect(firstRelease).not.toHaveBeenCalled();
    expect(previewLocalFile).toHaveBeenCalledOnce();
    expect(screen.getByRole("img", { name: attachment.fileName! })).toHaveAttribute(
      "src",
      "blob:visible-before-overlay"
    );

    rendered.unmount();
    expect(firstRelease).toHaveBeenCalledOnce();
    expect(secondRelease).not.toHaveBeenCalled();
  });

  it("loads image previews after a paused surface becomes visible without a new intersection", async () => {
    installIntersectionObserverHarness();
    const originalGetBoundingClientRect = Element.prototype.getBoundingClientRect;
    const geometry = vi
      .spyOn(Element.prototype, "getBoundingClientRect")
      .mockImplementation(function (this: Element) {
        if (this.getAttribute("data-slot") === "scroll-area-viewport") {
          return sizedElementRect(0, 480);
        }
        if (this.classList.contains("comma-chat-attachments")) {
          return sizedElementRect(120, 100);
        }
        return originalGetBoundingClientRect.call(this);
      });
    const attachment = localImageAttachment(0);
    const previewLocalFile = vi.fn(async () => ({
      release: vi.fn(),
      url: "blob:after-unpause",
    }));
    const thread = (
      <ConversationThread
        messages={[
          message("msg_unpause_image", "user", "", {
            attachments: [attachment],
          }),
        ]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );
    const rendered = render(<div data-comma-surface-paused="true">{thread}</div>);
    expect(previewLocalFile).not.toHaveBeenCalled();

    act(() => {
      (rendered.container.firstElementChild as HTMLElement).removeAttribute(
        "data-comma-surface-paused"
      );
    });
    await waitFor(() =>
      expect(previewLocalFile).toHaveBeenCalledWith(
        attachment.localFileRef,
        expect.any(AbortSignal)
      )
    );
    await waitForNamedImageSrc(attachment.fileName!, "blob:after-unpause");

    rendered.unmount();
    geometry.mockRestore();
  });

  it("ignores a stale leave while the image is still inside the activation band", async () => {
    const observer = installIntersectionObserverHarness();
    const attachment = localImageAttachment(0);
    const firstRelease = vi.fn();
    const previewLocalFile = vi.fn(async () => ({
      release: firstRelease,
      url: "blob:visible-after-stale-leave",
    }));
    const rendered = render(
      <ConversationThread
        messages={[
          message("msg_stale_leave_image", "user", "", {
            attachments: [attachment],
          }),
        ]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const observed = observer.firstObserved();
    const root = observed.closest("[data-slot='scroll-area-viewport']");
    expect(root).toBeInstanceOf(HTMLElement);
    vi.spyOn(observed, "getBoundingClientRect").mockReturnValue(
      domRect(0, 120, 240, 80)
    );
    vi.spyOn(root as HTMLElement, "getBoundingClientRect").mockReturnValue(
      domRect(0, 0, 720, 640)
    );

    observer.notify("inner", observed, true);
    await waitForNamedImageSrc(attachment.fileName!, "blob:visible-after-stale-leave");

    observer.notify("outer", observed, false);

    expect(firstRelease).not.toHaveBeenCalled();
    expect(previewLocalFile).toHaveBeenCalledOnce();
    expect(screen.getByRole("img", { name: attachment.fileName! })).toHaveAttribute(
      "src",
      "blob:visible-after-stale-leave"
    );

    rendered.unmount();
    expect(firstRelease).toHaveBeenCalledOnce();
  });

  it("releases a preview that fails to decode without painting a fake image", async () => {
    const observer = installIntersectionObserverHarness();
    const attachment = localImageAttachment(0);
    const release = vi.fn();
    const previewLocalFile = vi.fn(async () => ({
      release,
      url: "blob:local-image-decode-error",
    }));
    const rendered = render(
      <ConversationThread
        messages={[
          message("msg_decode_error", "user", "", {
            attachments: [attachment],
          }),
        ]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    observer.notify("inner", observer.firstObserved(), true);
    await waitForNamedImageSrc(attachment.fileName!, "blob:local-image-decode-error");
    const image = screen
      .getAllByRole("img", { name: attachment.fileName! })
      .find(
        (element) => element.getAttribute("src") === "blob:local-image-decode-error"
      );
    expect(image).toBeTruthy();
    fireEvent.error(image!);

    await waitFor(() => expect(release).toHaveBeenCalledOnce());
    expect(rendered.container.querySelector(".chat-panel-image-group")).toBeNull();
    expect(screen.queryByRole("img", { name: attachment.fileName! })).toBeNull();
    expect(screen.getByText(attachment.fileName!)).toBeInTheDocument();
    expect(previewLocalFile).toHaveBeenCalledOnce();
  });

  it("releases an offscreen image load, ignores its late result, and reloads on re-entry", async () => {
    const observer = installIntersectionObserverHarness();
    const attachment = localImageAttachment(0);
    const firstRelease = vi.fn();
    const secondRelease = vi.fn();
    let resolveFirst: ((preview: { release(): void; url: string }) => void) | undefined;
    const previewLocalFile = vi
      .fn<
        (previewRef: ChatImagePreviewRef) => Promise<
          | {
              release(): void;
              url: string;
            }
          | undefined
        >
      >()
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveFirst = resolve;
          })
      )
      .mockResolvedValueOnce({
        release: secondRelease,
        url: "blob:visible-after-reentry",
      });
    const rendered = render(
      <ConversationThread
        messages={[
          message("msg_visibility_image", "user", "", {
            attachments: [attachment],
          }),
        ]}
        onDiscard={() => {}}
        onPreviewLocalFile={previewLocalFile}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(previewLocalFile).not.toHaveBeenCalled();
    const observed = observer.firstObserved();
    observer.notify("inner", observed, true);
    await waitFor(() =>
      expect(previewLocalFile).toHaveBeenCalledWith(
        attachment.localFileRef,
        expect.any(AbortSignal)
      )
    );

    observer.notify("outer", observed, false);
    await act(async () => {
      resolveFirst?.({ release: firstRelease, url: "blob:stale-offscreen-result" });
      await Promise.resolve();
    });
    await waitFor(() => expect(firstRelease).toHaveBeenCalledOnce());
    expect(rendered.container.querySelector(".chat-panel-image-group")).not.toBeNull();
    expect(
      rendered.container.querySelector("[data-comma-image-group-placeholder]")
    ).not.toBeNull();
    expect(screen.queryByRole("img", { name: attachment.fileName! })).toBeNull();

    observer.notify("inner", observed, true);
    await waitForNamedImageSrc(attachment.fileName!, "blob:visible-after-reentry");
    expect(previewLocalFile).toHaveBeenCalledTimes(2);

    rendered.unmount();
    expect(secondRelease).toHaveBeenCalledOnce();
  });

  it("mounts only the latest rounds until the user scrolls toward older history", async () => {
    const history = historyTurns(20);
    const rendered = render(
      <ConversationThread
        messages={history}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const thread = rendered.container.querySelector(".comma-chat-thread");
    expect(thread).toHaveAttribute(
      "data-comma-hidden-older-count",
      String(20 - CONVERSATION_TURN_WINDOW.initialTurns)
    );
    expect(
      rendered.container.querySelector('[data-message-id="msg_hist_0"]')
    ).toBeNull();
    expect(
      rendered.container.querySelector('[data-message-id="msg_hist_13"]')
    ).toBeNull();
    expect(
      rendered.container.querySelector('[data-message-id="msg_hist_19"]')
    ).not.toBeNull();

    const viewport = rendered.container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );
    expect(viewport).toBeTruthy();
    mockScrollport(viewport!, { clientHeight: 480, scrollHeight: 2400, scrollTop: 0 });
    fireEvent.wheel(viewport!, { deltaY: -120 });
    fireEvent.scroll(viewport!);

    await waitFor(() =>
      expect(thread).toHaveAttribute(
        "data-comma-hidden-older-count",
        String(
          20 -
            CONVERSATION_TURN_WINDOW.initialTurns -
            CONVERSATION_TURN_WINDOW.pageTurns
        )
      )
    );
    expect(
      rendered.container.querySelector('[data-message-id="msg_hist_6"]')
    ).not.toBeNull();
    expect(
      rendered.container.querySelector('[data-message-id="msg_hist_0"]')
    ).toBeNull();
    expect(
      rendered.container.querySelector('[data-message-id="msg_hist_19"]')
    ).not.toBeNull();
  });

  it.each(["user_chat", "agent_task"] as const)(
    "bounds a long %s turn and reveals older messages without splitting its logical turn",
    async (conversationKind) => {
      const history = Array.from({ length: 96 }, (_, index) =>
        message(`msg_long_${index}`, "assistant", `Progress ${index}`)
      );
      const rendered = render(
        <ConversationThread
          conversationKind={conversationKind}
          messages={history}
          onDiscard={() => {}}
          onRetry={() => {}}
          groupId="grp_1"
          workspaceId="wsp_1"
        />
      );
      expect(
        rendered.container.querySelectorAll("article[data-message-id]").length
      ).toBeLessThanOrEqual(24);
      expect(screen.queryByText("Progress 0")).toBeNull();
      expect(screen.getByText("Progress 95")).toBeInTheDocument();
      expect(
        rendered.container.querySelectorAll(".comma-chat-turn-shell")
      ).toHaveLength(1);
      const viewport = rendered.container.querySelector<HTMLElement>(
        '[data-slot="scroll-area-viewport"]'
      )!;
      mockScrollport(viewport, { clientHeight: 480, scrollHeight: 2400, scrollTop: 0 });
      fireEvent.wheel(viewport, { deltaY: -120 });
      fireEvent.scroll(viewport);
      await waitFor(() => expect(screen.getByText("Progress 40")).toBeInTheDocument());
      expect(screen.queryByText("Progress 0")).toBeNull();
      expect(screen.getByText("Progress 95")).toBeInTheDocument();
      expect(
        rendered.container.querySelectorAll(".comma-chat-turn-shell")
      ).toHaveLength(1);
    }
  );

  it("slides the mounted window to the latest rounds while pinned to the bottom", () => {
    const rendered = render(
      <ConversationThread
        messages={historyTurns(20)}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(
      rendered.container.querySelector('[data-message-id="msg_hist_14"]')
    ).not.toBeNull();

    rendered.rerender(
      <ConversationThread
        messages={historyTurns(21)}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(
      rendered.container.querySelector('[data-message-id="msg_hist_14"]')
    ).toBeNull();
    expect(
      rendered.container.querySelector('[data-message-id="msg_hist_20"]')
    ).not.toBeNull();
    expect(rendered.container.querySelector(".comma-chat-thread")).toHaveAttribute(
      "data-comma-hidden-older-count",
      String(21 - CONVERSATION_TURN_WINDOW.initialTurns)
    );
  });

  it("does not slide the window while the user is reading older turns", async () => {
    const rendered = render(
      <ConversationThread
        messages={historyTurns(20)}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );
    const viewport = rendered.container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    );
    expect(viewport).toBeTruthy();
    mockScrollport(viewport!, { clientHeight: 480, scrollHeight: 2400, scrollTop: 0 });
    fireEvent.wheel(viewport!, { deltaY: -120 });
    fireEvent.scroll(viewport!);

    await waitFor(() =>
      expect(
        rendered.container.querySelector('[data-message-id="msg_hist_6"]')
      ).not.toBeNull()
    );

    rendered.rerender(
      <ConversationThread
        messages={historyTurns(21)}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    await waitFor(() => {
      expect(
        rendered.container.querySelector('[data-message-id="msg_hist_6"]')
      ).not.toBeNull();
      expect(
        rendered.container.querySelector('[data-message-id="msg_hist_14"]')
      ).not.toBeNull();
      expect(
        rendered.container.querySelector('[data-message-id="msg_hist_20"]')
      ).not.toBeNull();
    });
  });

  for (const variant of ["default", "side-chat"] as const) {
    it(`releases response aliases with the mounted turn window in ${variant}`, async () => {
      const user = message("window_user", "user", "First turn");
      const draft = {
        conversationId: "cnv_1",
        draftId: "window_draft",
        responseKey: "window_response",
        sourceMessageIds: [user.messageId],
        status: "streaming" as const,
        text: "First response",
      };
      const props = {
        onDiscard: () => {},
        onRetry: () => {},
        groupId: "grp_1",
        workspaceId: "wsp_1",
        variant,
      };
      const view = render(
        <ConversationThread {...props} messages={[user]} assistantDraft={draft} />
      );
      const firstRow = screen.getByTestId("chat-assistant-draft");
      const canonical = message("window_reply", "assistant", draft.text);
      view.rerender(<ConversationThread {...props} messages={[user, canonical]} />);
      expect(view.container.querySelector('[data-message-id="window_reply"]')).toBe(
        firstRow
      );
      const messages = [user, canonical, ...historyTurns(8)];
      view.rerender(<ConversationThread {...props} messages={messages} />);
      expect(firstRow).not.toBeInTheDocument();
      const viewport = view.container.querySelector<HTMLElement>(
        '[data-slot="scroll-area-viewport"]'
      )!;
      mockScrollport(viewport, { clientHeight: 480, scrollHeight: 2400, scrollTop: 0 });
      fireEvent.wheel(viewport, { deltaY: -120 });
      fireEvent.scroll(viewport);
      await waitFor(() =>
        expect(
          view.container.querySelector('[data-message-id="window_reply"]')
        ).not.toBeNull()
      );
      // Remounting intentionally reads canonical history. It needs no retained
      // conversation-wide draft alias to display the exact committed content.
      expect(screen.getByTestId("markdown-message:window_reply")).toHaveTextContent(
        draft.text
      );
      expect(view.container.querySelector('[data-message-id="window_reply"]')).not.toBe(
        firstRow
      );
    });
  }

  it("renders streaming assistant text in a response bubble without announcing a reply", async () => {
    const conversation = renderStatefulConversation(
      state({ messages: [message("msg_1", "user", "先查一下。")] })
    );
    await screen.findByText("先查一下。");

    const liveRegion = conversation.container.querySelector(
      '.app-sr-only[aria-live="polite"]'
    );
    expect(liveRegion).toHaveTextContent("");

    act(() => {
      conversation.setState(
        state({
          assistantDraft: {
            conversationId: "cnv_1",
            draftId: "draft_1",
            responseKey: "draft_1",
            sourceMessageIds: ["msg_1"],
            status: "streaming",
            text: "正在整理 **第一版**。",
          },
          messages: [message("msg_1", "user", "先查一下。")],
        })
      );
    });

    const draft = await screen.findByTestId("chat-assistant-draft");
    expect(draft).toHaveTextContent("正在整理 **第一版**。");
    expect(draft).toHaveAttribute("data-slot", "chat-assistant-output");
    expect(liveRegion).toHaveTextContent("");
  });

  it("installs the canonical Message and its attachment into the same response node", async () => {
    const prompt = message("msg_handoff_user", "user", "开始");
    const conversation = renderStatefulConversation(
      state({
        assistantDraft: {
          conversationId: "cnv_1",
          draftId: "draft_handoff",
          responseKey: "rsp_handoff",
          sourceMessageIds: [prompt.messageId],
          status: "completed",
          text: "完成内容",
        },
        messages: [prompt],
      })
    );
    const draftNode = await screen.findByTestId("chat-assistant-draft");

    act(() => {
      conversation.setState(
        state({
          messages: [
            prompt,
            message("msg_handoff_final", "assistant", "完成内容", {
              attachments: [
                {
                  blockType: "file",
                  fileName: "result.pdf",
                  mimeType: "application/pdf",
                  size: 2048,
                  title: "result.pdf",
                },
              ],
            }),
          ],
        })
      );
    });

    const finalNode = containerArticle(conversation.container, "msg_handoff_final");
    expect(finalNode).toBe(draftNode);
    expect(finalNode).toHaveTextContent("完成内容");
    expect(await screen.findByText("result.pdf")).toBeInTheDocument();
  });

  it("copies assistant messages without embedding timestamps in the hover action row", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal("navigator", {
      clipboard: { writeText },
    });
    render(
      <ConversationThread
        messages={[message("msg_1", "assistant", "查好了。", { createdAt: 1 })]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const copyButton = await screen.findByRole("button", { name: "Copy reply" });
    const copyStateIcon = copyButton.querySelector(".t-icon-swap");
    expect(copyButton).toHaveAttribute("data-no-press-feedback");
    expect(copyStateIcon).toHaveAttribute("data-state", "a");
    expect(copyStateIcon).toHaveAttribute("data-swap-blur", "none");
    expect(copyStateIcon?.querySelectorAll(".t-icon")).toHaveLength(2);
    expect(
      screen.getByTestId("chat-message-actions-msg_1").querySelector("time")
    ).toBeNull();

    fireEvent.click(copyButton);

    await waitFor(() => expect(writeText).toHaveBeenCalledWith("查好了。"));
    expect(await screen.findByRole("button", { name: "Copied" })).toBeInTheDocument();
    expect(copyStateIcon).toHaveAttribute("data-state", "b");
    const copiedIconLayer = copyStateIcon?.querySelector('[data-icon="b"]');
    expect(copiedIconLayer).toHaveClass("comma-chat-message-copy-success-icon");
    expect(copiedIconLayer?.querySelector("svg")).toHaveClass(
      "text-fg-success-primary"
    );
    await waitFor(
      () => {
        expect(screen.getByRole("button", { name: "Copy reply" })).toBeInTheDocument();
        expect(copyStateIcon).toHaveAttribute("data-state", "a");
      },
      { timeout: 1_200 }
    );
  });

  it("confirms a copied message on the toast stack and reports failures", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal("navigator", { clipboard: { writeText } });
    render(
      <>
        <Toaster />
        <ConversationThread
          messages={[message("msg_toast", "assistant", "Copy me.")]}
          onDiscard={() => {}}
          onRetry={() => {}}
          groupId="grp_1"
          workspaceId="wsp_1"
        />
      </>
    );

    const copyButton = await screen.findByRole("button", { name: "Copy reply" });
    fireEvent.click(copyButton);

    const copyToast = await screen.findByTestId("copy-feedback");
    expect(copyToast).toHaveTextContent("Copied message");
    expect(copyToast).toHaveTextContent("Message copied to clipboard");

    // A second copy reuses the same toast instead of stacking a new one.
    fireEvent.click(await screen.findByRole("button", { name: "Copied" }));
    await waitFor(() => expect(writeText).toHaveBeenCalledTimes(2));
    expect(screen.getAllByTestId("copy-feedback")).toHaveLength(1);

    writeText.mockRejectedValueOnce(new Error("clipboard blocked"));
    fireEvent.click(screen.getByRole("button", { name: "Copied" }));

    await waitFor(() =>
      expect(screen.getByTestId("copy-feedback")).toHaveTextContent("Couldn’t copy")
    );
    expect(screen.getAllByTestId("copy-feedback")).toHaveLength(1);
  });

  it("shows the Comma Copy tooltip for an assistant message action", async () => {
    const user = userEvent.setup();
    render(
      <ConversationThread
        messages={[message("msg_copy_tooltip", "assistant", "Ready to copy.")]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const copyButton = await screen.findByRole("button", { name: "Copy reply" });
    expect(copyButton).not.toHaveAttribute("title");

    setInteractionModality("pointer");
    await user.hover(copyButton);

    const tooltip = await screen.findByRole("tooltip");
    expect(tooltip).toHaveTextContent(/^Copy$/);
    expect(tooltip).toHaveAttribute("data-side", "bottom");
  });

  it("copies only the visible body of a user message from the Comma action", async () => {
    const user = userEvent.setup();
    const writeText = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal("navigator", { clipboard: { writeText } });
    const messageWithBody = composeMessageWithAttachments("请看这些文件", [
      { name: "report.txt", path: "/workspace/report.txt" },
    ]);
    const attachmentOnlyMessage = composeMessageWithAttachments("", [
      { name: "notes.txt", path: "/workspace/notes.txt" },
    ]);

    render(
      <ConversationThread
        messages={[
          message("msg_user_copy", "user", messageWithBody),
          message("msg_user_attachment_only", "user", attachmentOnlyMessage),
        ]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const copyButton = await screen.findByRole("button", { name: "Copy message" });
    const copyStateIcon = copyButton.querySelector(".t-icon-swap");
    expect(screen.getAllByRole("button", { name: "Copy message" })).toHaveLength(1);
    expect(copyButton).toHaveAttribute("data-no-press-feedback");
    expect(copyButton).not.toHaveAttribute("title");
    expect(copyStateIcon).toHaveAttribute("data-state", "a");
    expect(copyStateIcon).toHaveAttribute("data-swap-blur", "none");

    setInteractionModality("pointer");
    await user.hover(copyButton);

    const tooltip = await screen.findByRole("tooltip");
    expect(tooltip).toHaveTextContent(/^Copy$/);
    expect(tooltip).toHaveAttribute("data-side", "bottom");

    await user.click(copyButton);

    await waitFor(() => expect(writeText).toHaveBeenCalledWith("请看这些文件"));
    expect(await screen.findByRole("button", { name: "Copied" })).toBeInTheDocument();
    expect(copyStateIcon).toHaveAttribute("data-state", "b");

    await user.unhover(copyButton);
    await user.hover(copyButton);
    expect(await screen.findByRole("tooltip")).toHaveTextContent(/^Copy$/);
  });

  it("copies the ordered plain-text title of an inline Task", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    vi.stubGlobal("navigator", { clipboard: { writeText } });
    render(
      <ConversationThread
        messages={[
          message("msg_inline_copy", "assistant", "Created task.", {
            parts: [
              { kind: "markdown", text: "Created " },
              {
                kind: "inline-task",
                task: {
                  conversationId: "cnv_task_public",
                  title: "Deploy report",
                  unavailable: false,
                },
              },
              { kind: "markdown", text: "." },
            ],
          }),
        ]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    fireEvent.click(await screen.findByRole("button", { name: "Copy reply" }));

    await waitFor(() =>
      expect(writeText).toHaveBeenCalledWith("Created Deploy report.")
    );
  });

  it("centers one timestamp before the first user message in each minute interval", () => {
    const intervalStart = new Date();
    intervalStart.setHours(12, 0, 0, 0);
    const startedAt = intervalStart.getTime();
    const messages = [
      message("msg_start", "user", "Start the conversation", {
        createdAt: startedAt,
      }),
      message("msg_within", "user", "Still in the first interval", {
        createdAt: startedAt + 59_999,
      }),
      message("msg_next", "user", "Start the next interval", {
        createdAt: startedAt + 60_000,
      }),
      message("msg_next_within", "user", "Still in the next interval", {
        createdAt: startedAt + 119_999,
      }),
      message("msg_third", "user", "Start the third interval", {
        createdAt: startedAt + 120_000,
      }),
    ];

    render(
      <ConversationThread
        messages={messages}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const firstTimestamp = screen.getByTestId("chat-conversation-time-msg_start");
    const secondTimestamp = screen.getByTestId("chat-conversation-time-msg_next");
    const thirdTimestamp = screen.getByTestId("chat-conversation-time-msg_third");

    expect(firstTimestamp).toHaveAttribute(
      "dateTime",
      new Date(startedAt).toISOString()
    );
    expect(firstTimestamp).toHaveTextContent(/^Today /);
    expect(secondTimestamp).toBeInTheDocument();
    expect(thirdTimestamp).toBeInTheDocument();
    expect(screen.queryByTestId("chat-conversation-time-msg_within")).toBeNull();
    expect(screen.queryByTestId("chat-conversation-time-msg_next_within")).toBeNull();

    const thirdUser = screen.getByText("Start the third interval").closest("article");
    expect(thirdTimestamp.nextElementSibling).toBe(thirdUser);
  });

  it("omits message copy actions and conversation timestamps from side chat", () => {
    render(
      <ConversationThread
        messages={[
          message("msg_side_chat_user", "user", "简洁问题。", { createdAt: 1 }),
          message("msg_side_chat", "assistant", "简洁回复。", { createdAt: 1 }),
        ]}
        onDiscard={() => {}}
        onRetry={() => {}}
        variant="side-chat"
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(screen.getByText("简洁问题。")).toBeInTheDocument();
    expect(screen.getByText("简洁回复。")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Copy message" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Copy reply" })).toBeNull();
    expect(
      screen.queryByTestId("chat-conversation-time-msg_side_chat_user")
    ).toBeNull();
    expect(screen.queryByTestId("chat-conversation-time-msg_side_chat")).toBeNull();
    expect(screen.queryByTestId("chat-message-actions-msg_side_chat_user")).toBeNull();
    expect(screen.queryByTestId("chat-message-actions-msg_side_chat")).toBeNull();
  });

  it("shows browser inspection context beside the user prompt", () => {
    const inspectionMessage = [
      "为什么什么都没有",
      "",
      "<user-reminder>",
      '<browser-element-inspection id="inspection-visible" />',
      "<browser_element_context>",
      "Page title: Snake",
      "Page URL: http://snake.local",
      "Selector: body > textarea",
      "Tag: textarea",
      "",
      "Element text:",
      "test",
      "",
      "Element HTML excerpt:",
      "```html",
      "<textarea></textarea>",
      "```",
      "</browser_element_context>",
      "</user-reminder>",
    ].join("\n");

    render(
      <ConversationThread
        messages={[message("msg_inspection", "user", inspectionMessage)]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(screen.getByText("为什么什么都没有")).toBeInTheDocument();
    const context = screen.getByTestId("chat-browser-inspection-context");
    expect(context).toHaveTextContent("Snake");
    expect(context).toHaveTextContent("body > textarea");
    expect(context).toHaveTextContent("test");
    expect(screen.queryByText("<user-reminder>")).toBeNull();
  });

  it("shows canonical Task agent messages with their Router and Worker sources", async () => {
    vi.stubGlobal("crypto", process.getBuiltinModule("crypto").webcrypto);
    render(
      <ConversationThread
        messages={[
          message("msg_router", "assistant", "I assigned the work.", {
            actorRole: "router",
          }),
          message("msg_worker", "assistant", "I produced the result.", {
            actorId: "agt1_worker_1",
            actorRole: "worker",
          }),
        ]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(screen.getByText("Router")).toBeInTheDocument();
    expect(screen.getByText("Worker")).toBeInTheDocument();
    const routerMessage = screen.getByText("I assigned the work.").closest("article");
    const workerMessage = screen.getByText("I produced the result.").closest("article");

    expect(routerMessage).toHaveAttribute("data-actor-role", "router");
    expect(
      routerMessage?.querySelector('[data-slot="comma-product-mark"]')
    ).not.toBeNull();
    expect(workerMessage).toHaveAttribute("data-actor-role", "worker");
    expect(workerMessage?.querySelector('[data-slot="comma-product-mark"]')).toBeNull();
    await waitFor(() => {
      expect(
        workerMessage?.querySelector(".comma-chat-assistant-source-avatar svg")
      ).toBeNull();
      expect(
        workerMessage?.querySelector<HTMLElement>(".comma-chat-assistant-source-avatar")
          ?.style.backgroundImage
      ).toContain("radial-gradient");
    });
  });

  it("keeps after-message content visible in side chat", () => {
    const { container } = render(
      <ConversationThread
        afterMessages={<div data-testid="side-chat-after-messages">Review action</div>}
        messages={[message("msg_side_chat", "assistant", "Task result")]}
        onDiscard={() => {}}
        onRetry={() => {}}
        variant="side-chat"
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const afterMessages = screen.getByTestId("side-chat-after-messages");
    expect(afterMessages).toBeInTheDocument();
    expect(container.querySelector(".comma-chat-column")?.lastElementChild).toBe(
      afterMessages.parentElement
    );
  });

  it("holds each reply-owned tail in its own reply's turn, not the newest turn", () => {
    const messages = [
      message("msg_1", "user", "第一轮"),
      message("msg_2", "assistant", "第一轮回复"),
      message("msg_3", "user", "第二轮"),
      message("msg_4", "assistant", "第二轮回复"),
    ];
    const { container } = render(
      <ConversationThread
        anchoredTails={[
          {
            key: "first round",
            messageId: "msg_2",
            node: <div data-testid="first-reply-tail">Label proposal card</div>,
          },
          {
            key: "second round",
            messageId: "msg_4",
            node: <div data-testid="second-reply-tail">Label proposal card</div>,
          },
        ]}
        messages={messages}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const first = screen.getByTestId("first-reply-tail");
    const firstOwner = first.closest("[data-chat-turn-anchor]");
    expect(firstOwner).not.toBeNull();
    expect(firstOwner).toContainElement(
      container.querySelector('[data-message-id="msg_2"]')
    );
    // A later reply does not carry the earlier card.
    const second = screen.getByTestId("second-reply-tail");
    const secondOwner = second.closest("[data-chat-turn-anchor]");
    expect(secondOwner).not.toBeNull();
    expect(secondOwner).not.toBe(firstOwner);
    expect(secondOwner).toContainElement(
      container.querySelector('[data-message-id="msg_4"]')
    );
    // The newest turn carries only its own node, so nothing rides the tail.
    expect(screen.getByTestId("chat-latest-turn")).toContainElement(second);
    expect(screen.getByTestId("chat-latest-turn")).not.toContainElement(first);
  });

  it("anchors a new user turn even when the reader was scrolled away", () => {
    const messages = [message("msg_1", "assistant", "已整理前三项。")];
    const { container, rerender } = render(
      <ConversationThread
        messages={messages}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );
    const viewport = queryViewport(container);
    setElementMetric(viewport, "clientHeight", 100);
    setElementMetric(viewport, "scrollHeight", 620);
    viewport.scrollTop = 0;
    fireEvent.wheel(viewport, { deltaY: -120 });
    fireEvent.scroll(viewport);
    const geometry = vi
      .spyOn(HTMLElement.prototype, "getBoundingClientRect")
      .mockImplementation(function (this: HTMLElement) {
        if (this === viewport) return elementRect(100);
        if (this.dataset.turnKey === "req_1") return elementRect(640);
        return elementRect(0);
      });

    rerender(
      <ConversationThread
        messages={[
          ...messages,
          message("pending:req_1", "user", "再补充风险项。", {
            clientRequestId: "req_1",
            delivery: "sending",
            source: "pending",
          }),
        ]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(viewport.scrollTop).toBe(520);
    expect(screen.queryByRole("button", { name: /new messages/ })).toBeNull();
    geometry.mockRestore();
  });

  it("keeps cold pending user messages static without a local launch transaction", () => {
    const pending = message("pending:req_motion", "user", "带动画进入", {
      clientRequestId: "req_motion",
      delivery: "sending",
      source: "pending",
    });
    const view = render(
      <ConversationThread
        messages={[pending]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );
    const pendingRow = view.container.querySelector(
      '[data-message-id="pending:req_motion"]'
    );

    expect(pendingRow).not.toBeNull();
    const bubble = pendingRow?.querySelector(".comma-chat-user-bubble");
    expect(bubble).toHaveTextContent("带动画进入");
    expect(bubble).not.toHaveAttribute("data-outgoing-presentation");
  });

  it("updates cumulative draft text in one stable response node", async () => {
    const view = renderStatefulConversation(
      state({
        assistantDraft: burstAssistantDraft("A", "streaming"),
        messages: [message("msg_burst_user", "user", "快速输出")],
      })
    );
    const response = await screen.findByTestId("chat-assistant-draft");

    act(() => {
      view.setState(
        state({
          assistantDraft: burstAssistantDraft("ABC", "streaming"),
          messages: [message("msg_burst_user", "user", "快速输出")],
        })
      );
    });

    expect(screen.getByTestId("chat-assistant-draft")).toBe(response);
    await waitFor(() => expect(response).toHaveTextContent("ABC"));
  });

  it("rechecks meaningful overflow when the anchored inner turn resizes", () => {
    vi.useFakeTimers();
    let resizeCallback: ResizeObserverCallback | undefined;
    let resizeObserver: ResizeObserver | undefined;
    const observe = vi.fn();

    class MockResizeObserver {
      readonly observe = observe;
      readonly unobserve = vi.fn();
      readonly disconnect = vi.fn();

      constructor(callback: ResizeObserverCallback) {
        resizeCallback = callback;
        resizeObserver = this as unknown as ResizeObserver;
      }
    }

    vi.stubGlobal("ResizeObserver", MockResizeObserver);

    const view = render(
      <ConversationThread
        assistantDraft={burstAssistantDraft("Keep streaming", "streaming")}
        messages={[message("msg_scroll_user", "user", "Keep streaming")]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );
    const viewport = queryViewport(view.container);
    const latestTurn = screen.getByTestId("chat-latest-turn");
    const currentTurn = screen.getByTestId("chat-current-turn");
    const content = view.container.querySelector('[data-slot="scroll-area-content"]');
    const thread = view.container.querySelector<HTMLElement>(".comma-chat-thread");
    const verticalScrollbars = () =>
      view.container.querySelectorAll(
        '[data-slot="scroll-area-scrollbar"][data-axis="vertical"]'
      );

    expect(content).not.toBeNull();
    expect(thread).not.toBeNull();
    expect(resizeCallback).toBeDefined();
    expect(observe).toHaveBeenCalledWith(currentTurn);

    setElementMetric(viewport, "clientHeight", 500);
    setElementMetric(viewport, "clientWidth", 700);
    setElementMetric(viewport, "scrollHeight", 620);
    setElementMetric(thread!, "scrollHeight", 620);
    setElementMetric(latestTurn, "clientHeight", 400);
    setElementMetric(currentTurn, "scrollHeight", 400);
    let scrollTop = 0;
    let scrollTopWrites = 0;
    Object.defineProperty(viewport, "scrollTop", {
      configurable: true,
      get: () => scrollTop,
      set: (value: number) => {
        scrollTop = value;
        scrollTopWrites += 1;
      },
    });
    expect(verticalScrollbars()).toHaveLength(0);

    act(() => {
      resizeCallback?.(
        [{ target: content! } as unknown as ResizeObserverEntry],
        resizeObserver!
      );
    });

    expect(latestTurn).toHaveClass("comma-chat-latest-turn");
    expect(verticalScrollbars()).toHaveLength(1);

    scrollTopWrites = 0;
    act(() => {
      resizeCallback?.(
        [{ target: currentTurn } as unknown as ResizeObserverEntry],
        resizeObserver!
      );
    });
    expect(scrollTopWrites).toBe(0);

    setElementMetric(viewport, "scrollHeight", 700);
    setElementMetric(thread!, "scrollHeight", 700);
    setElementMetric(latestTurn, "clientHeight", 480);
    setElementMetric(currentTurn, "scrollHeight", 100);
    act(() => {
      resizeCallback?.(
        [{ target: currentTurn } as unknown as ResizeObserverEntry],
        resizeObserver!
      );
    });

    expect(latestTurn).not.toHaveClass("comma-chat-latest-turn");
    expect(verticalScrollbars()).toHaveLength(0);
    expect(scrollTopWrites).toBeGreaterThan(0);

    setElementMetric(viewport, "clientWidth", 640);
    setElementMetric(viewport, "scrollHeight", 760);
    setElementMetric(thread!, "scrollHeight", 760);
    setElementMetric(latestTurn, "clientHeight", 540);
    setElementMetric(currentTurn, "scrollHeight", 460);
    scrollTopWrites = 0;
    act(() => {
      resizeCallback?.(
        [{ target: currentTurn } as unknown as ResizeObserverEntry],
        resizeObserver!
      );
    });

    expect(verticalScrollbars()).toHaveLength(1);
    expect(scrollTopWrites).toBeGreaterThan(0);
  });

  it("groups the latest user message and response without forcing short content to scroll", () => {
    const { container } = render(
      <ConversationThread
        messages={[
          message("msg_user_1", "user", "旧问题"),
          message("msg_assistant_1", "assistant", "旧回答"),
          message("msg_user_2", "user", "新问题"),
          message("msg_assistant_2", "assistant", "正在回答新问题"),
        ]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const latestTurn = screen.getByTestId("chat-current-turn");
    expect(latestTurn).toContainElement(screen.getByText("新问题"));
    expect(latestTurn).toContainElement(screen.getByText("正在回答新问题"));
    expect(latestTurn).not.toContainElement(screen.getByText("旧问题"));
    expect(latestTurn).not.toContainElement(screen.getByText("旧回答"));
    expect(container.querySelector('[data-message-id="msg_user_1"]')).not.toBeNull();
    expect(latestTurn.closest('[data-chat-latest-turn="true"]')).not.toBeNull();
    expect(latestTurn.closest(".comma-chat-latest-turn")).toBeNull();
  });

  it("groups assistant messages in transcript order under the current user turn", () => {
    const { container } = render(
      <ConversationThread
        messages={[
          message("msg_u1", "user", "First input"),
          message("msg_u2", "user", "Second input"),
          message("msg_a1", "assistant", "Late first reply"),
          message("msg_a2", "assistant", "Combined reply"),
          message("msg_unowned", "assistant", "Unowned reply"),
        ]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    const firstTurn = container.querySelector('[data-turn-key="msg_u1"]');
    const secondTurn = container.querySelector('[data-turn-key="msg_u2"]');
    const unowned = container.querySelector<HTMLElement>(
      '[data-message-id="msg_unowned"]'
    );
    expect(firstTurn).not.toHaveTextContent("Late first reply");
    expect(firstTurn).not.toHaveTextContent("Combined reply");
    expect(secondTurn).toHaveTextContent("Late first reply");
    expect(secondTurn).toHaveTextContent("Combined reply");
    expect(secondTurn).toContainElement(unowned);
  });

  it("keeps a Task transcript with only non-user messages in one latest-turn group", () => {
    const { container } = render(
      <ConversationThread
        messages={[
          message("msg_task_1", "assistant", "Task started"),
          message("msg_task_2", "assistant", "Task is running"),
          message("msg_task_3", "assistant", "Task completed"),
        ]}
        groupId="grp_1"
        onDiscard={() => {}}
        onRetry={() => {}}
        workspaceId="wsp_1"
      />
    );

    const turnShells = container.querySelectorAll(".comma-chat-turn-shell");
    const latestTurn = screen.getByTestId("chat-current-turn");
    expect(turnShells).toHaveLength(1);
    expect(latestTurn).toContainElement(screen.getByText("Task started"));
    expect(latestTurn).toContainElement(screen.getByText("Task is running"));
    expect(latestTurn).toContainElement(screen.getByText("Task completed"));
  });

  it("places an unowned assistant draft at the transcript tail", async () => {
    const view = renderStatefulConversation(
      state({
        assistantDraft: {
          conversationId: "cnv_1",
          draftId: "draft_unowned",
          responseKey: "rsp_unowned",
          sourceMessageIds: ["msg_missing"],
          status: "streaming",
          text: "Current draft",
        },
        messages: [message("msg_latest", "user", "Visible input")],
      })
    );

    const draft = await screen.findByTestId("chat-assistant-draft");
    const slot = screen.getByTestId("participant-status-slot");
    expect(draft).toHaveTextContent("Current draft");
    expect(screen.getByText("Visible input")).toBeInTheDocument();
    expect(
      view.container.querySelector('[data-message-id="msg_latest"]')?.nextElementSibling
    ).toBe(draft);
    expect(draft.nextElementSibling).toBe(slot);
  });

  it("renders an optimistic user message without a sending label", async () => {
    vi.useFakeTimers();
    render(
      <ConversationThread
        messages={[
          message("pending:req_1", "user", "快速发送", {
            clientRequestId: "req_1",
            delivery: "sending",
            source: "pending",
          }),
        ]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(screen.getByText("快速发送")).toBeInTheDocument();
    expect(screen.queryByText("Sending")).toBeNull();
    expect(screen.getByRole("button", { name: "Copy message" })).toBeInTheDocument();

    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_000);
    });
    expect(screen.queryByText("Sending")).toBeNull();
  });

  it("shows optimistic thinking until a streamed reply takes over", async () => {
    const optimisticMessage = message("pending:req_1", "user", "开始吧", {
      clientRequestId: "req_1",
      delivery: "sending",
      source: "pending",
    });
    const view = renderStatefulConversation(
      state({
        awaitingReply: true,
        locallyAwaitingReply: true,
        messages: [optimisticMessage],
      })
    );

    expect(await screen.findByText("开始吧")).toBeInTheDocument();
    expect(screen.getByText("Thinking")).toBeInTheDocument();
    expect(screen.queryByText("Sending")).toBeNull();

    act(() =>
      view.setState(
        state({
          assistantDraft: {
            conversationId: "cnv_1",
            draftId: "draft_1",
            responseKey: "rsp_1",
            sourceMessageIds: ["pending:req_1"],
            status: "streaming",
            text: "正在生成真实回复",
          },
          awaitingReply: true,
          locallyAwaitingReply: true,
          messages: [optimisticMessage],
        })
      )
    );

    expect(await screen.findByTestId("chat-assistant-draft")).toHaveTextContent(
      "正在生成真实回复"
    );
    expect(screen.queryByText("Typing")).toBeNull();
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "data-active",
      "false"
    );
  });

  for (const variant of ["route", "side-chat"] as const) {
    it(`hands waiting to the first response and keeps later feedback after it in ${variant}`, async () => {
      const user = message("msg_user", "user", "Start this turn");
      const participant = {
        conversationId: "cnv_1",
        participantId: "router",
        state: "active" as const,
        status: "is thinking...",
        updatedAt: 1,
      };
      const base = { messages: [user], participantStatus: participant };
      const view = renderStatefulConversation(
        state({ ...base, awaitingReply: true, locallyAwaitingReply: true }),
        createActions(),
        variant
      );
      const slot = await screen.findByTestId("participant-status-slot");
      const mark = slot.querySelector('[data-slot="comma-logo-animation"]');
      expect(slot).toHaveAttribute("data-active", "true");
      const draft = {
        conversationId: "cnv_1",
        draftId: "draft_handoff",
        responseKey: "rsp_handoff",
        sourceMessageIds: [user.messageId],
        status: "streaming" as const,
        text: "",
      };
      act(() => view.setState(state({ ...base, assistantDraft: draft })));
      expect(screen.queryByTestId("chat-assistant-draft")).toBeNull();
      expect(slot).toHaveAttribute("data-active", "true");
      expect(slot.querySelector('[data-slot="comma-logo-animation"]')).toBe(mark);
      act(() =>
        view.setState(
          state({ ...base, assistantDraft: { ...draft, text: "First reply" } })
        )
      );
      const article = screen.getByTestId("chat-assistant-draft");
      expect(slot).toHaveAttribute("data-active", "false");
      expect(
        article.compareDocumentPosition(slot) & Node.DOCUMENT_POSITION_FOLLOWING
      ).toBeTruthy();
      const canonical = message("msg_final", "assistant", "First reply");
      act(() =>
        view.setState(
          state({
            ...base,
            messages: [user, canonical],
            awaitingReply: true,
            locallyAwaitingReply: true,
          })
        )
      );
      expect(view.container.querySelector('[data-message-id="msg_final"]')).toBe(
        article
      );
      expect(article).not.toHaveClass("comma-side-chat-assistant-entry");
      // The canonical first reply does not end the Participant's work.
      expect(slot).toHaveAttribute("data-active", "true");
      await waitFor(() => expect(slot).toHaveTextContent("Working"));
      act(() =>
        view.setState(
          state({
            ...base,
            messages: [user, canonical],
            participantStatus: {
              ...participant,
              issue: "runtime_failed",
              state: "error",
              status: "error: runtime failed",
            },
          })
        )
      );
      expect(slot).toHaveAttribute("data-state", "error");
      await waitFor(() =>
        expect(slot).toHaveTextContent(
          "Stopped because of an error. Try sending again."
        )
      );
      expect(
        article.compareDocumentPosition(slot) & Node.DOCUMENT_POSITION_FOLLOWING
      ).toBeTruthy();
      act(() =>
        view.setState(
          state({
            messages: [user, canonical],
            awaitingReply: true,
            awaitingTimedOut: true,
          })
        )
      );
      expect(slot).toHaveAttribute("data-state", "waiting");
      expect(
        article.compareDocumentPosition(slot) & Node.DOCUMENT_POSITION_FOLLOWING
      ).toBeTruthy();
      act(() =>
        view.setState(
          state({
            messages: [user, canonical, message("msg_next", "user", "Next turn")],
            awaitingReply: true,
            locallyAwaitingReply: true,
          })
        )
      );
      const nextSlot = screen.getByTestId("participant-status-slot");
      expect(nextSlot).toHaveAttribute("data-active", "true");
      expect(nextSlot).toHaveTextContent("Thinking");
      expect(view.container.querySelector('[data-message-id="msg_final"]')).toBe(
        article
      );
      act(() =>
        view.setState(
          state({
            messages: [user, canonical, message("msg_next", "user", "Next turn")],
            assistantDraft: {
              ...draft,
              draftId: "draft_next",
              responseKey: "rsp_next",
              sourceMessageIds: ["msg_next"],
              text: "Second reply",
            },
          })
        )
      );
      expect(view.container.querySelector('[data-message-id="msg_final"]')).toBe(
        article
      );
      expect(article).not.toHaveClass("comma-side-chat-assistant-entry");
    });
  }

  for (const variant of ["route", "side-chat"] as const) {
    for (const leading of [false, true]) {
      it(`keeps reply identity through same-turn replies and prepended history in ${variant} (${leading ? "leading" : "user"} turn)`, async () => {
        const user = message("identity_user", "user", "Start");
        const prefix = leading ? [] : [user];
        const draft = {
          conversationId: "cnv_1",
          draftId: "identity_draft_1",
          responseKey: "identity_response_1",
          sourceMessageIds: leading ? [] : [user.messageId],
          status: "streaming" as const,
          text: "First reply",
        };
        const view = renderStatefulConversation(
          state({ messages: prefix, assistantDraft: draft }),
          createActions(),
          variant
        );
        const firstRow = await screen.findByTestId("chat-assistant-draft");
        const first = message("identity_first", "assistant", "First reply");
        act(() => view.setState(state({ messages: [...prefix, first] })));
        expect(view.container.querySelector('[data-message-id="identity_first"]')).toBe(
          firstRow
        );
        // A second response may belong to the same user turn. Keep the first
        // visual alias while assigning the second response its own identity.
        const secondDraft = {
          ...draft,
          draftId: "identity_draft_2",
          // One activation can send multiple Messages. The observed clear
          // between these drafts is the new visual-row lifetime boundary.
          responseKey: draft.responseKey,
          text: "Second reply",
        };
        act(() =>
          view.setState(
            state({ messages: [...prefix, first], assistantDraft: secondDraft })
          )
        );
        const secondRow = screen.getByTestId("chat-assistant-draft");
        expect(secondRow).not.toBe(firstRow);
        const second = message("identity_second", "assistant", "Second reply");
        act(() => view.setState(state({ messages: [...prefix, first, second] })));
        expect(view.container.querySelector('[data-message-id="identity_first"]')).toBe(
          firstRow
        );
        expect(
          view.container.querySelector('[data-message-id="identity_second"]')
        ).toBe(secondRow);
        // Insert older canonical rows inside this same turn; row identity must
        // follow ids, never response ordinal or the first entry in the turn.
        const older = message(
          "identity_older",
          "assistant",
          "Previously loaded history"
        );
        const withHistory = [...prefix, older, first, second];
        act(() => view.setState(state({ messages: withHistory })));
        expect(view.container.querySelector('[data-message-id="identity_first"]')).toBe(
          firstRow
        );
        expect(
          view.container.querySelector('[data-message-id="identity_second"]')
        ).toBe(secondRow);
        const historicalRow = view.container.querySelector(
          '[data-message-id="identity_older"]'
        );
        // A reconnect can change draftId while preserving the composite reply.
        const thirdDraft = {
          ...draft,
          draftId: "identity_draft_3",
          responseKey: "identity_response_3",
          text: "Third reply",
        };
        act(() =>
          view.setState(state({ messages: withHistory, assistantDraft: thirdDraft }))
        );
        const thirdRow = screen.getByTestId("chat-assistant-draft");
        act(() =>
          view.setState(
            state({
              messages: withHistory,
              assistantDraft: { ...thirdDraft, draftId: "reconnected_draft" },
            })
          )
        );
        expect(screen.getByTestId("chat-assistant-draft")).toBe(thirdRow);
        // A different source binding is an independent response even when its
        // opaque response key is reused. It cannot inherit the old pixels.
        act(() =>
          view.setState(
            state({
              messages: withHistory,
              assistantDraft: {
                ...thirdDraft,
                sourceMessageIds: ["different-source"],
                text: "Independent reply",
              },
            })
          )
        );
        const independentRow = screen.getByTestId("chat-assistant-draft");
        expect(independentRow).not.toBe(thirdRow);
        // Clearing without a canonical replacement retires only that draft.
        // A later ordinary canonical message must not acquire its old key.
        act(() => view.setState(state({ messages: withHistory })));
        const later = message("identity_later", "assistant", "Later ordinary message");
        act(() => view.setState(state({ messages: [...withHistory, later] })));
        const laterRow = view.container.querySelector(
          '[data-message-id="identity_later"]'
        );
        expect(laterRow).not.toBe(independentRow);
        expect(
          screen.getByTestId("markdown-message:identity_later")
        ).toBeInTheDocument();
        expect(view.container.querySelector('[data-message-id="identity_first"]')).toBe(
          firstRow
        );
        expect(
          view.container.querySelector('[data-message-id="identity_second"]')
        ).toBe(secondRow);
        expect(view.container.querySelector('[data-message-id="identity_older"]')).toBe(
          historicalRow
        );
        expect(firstRow).not.toHaveClass("comma-side-chat-assistant-entry");
        expect(secondRow).not.toHaveClass("comma-side-chat-assistant-entry");
      });
    }
  }

  it.each([
    {
      name: "keeps optimistic thinking for the current send beside an older failure",
      text: "重新开始",
      thinking: true,
      build: () => {
        const failed = pendingSend("req_failed", "先前失败", "failed");
        const current = pendingSend("req_current", "重新开始", "sending");
        return state({
          awaitingReply: true,
          awaitingTurnKey: current.clientRequestId,
          locallyAwaitingReply: true,
          messages: [pendingMessage(failed), pendingMessage(current)],
          pending: [failed, current],
        });
      },
    },
    {
      name: "does not show optimistic thinking for a failed current send",
      text: "当前失败",
      thinking: false,
      build: () => {
        const failed = pendingSend("req_failed", "当前失败", "failed");
        return state({
          awaitingReply: true,
          awaitingTurnKey: failed.clientRequestId,
          locallyAwaitingReply: true,
          messages: [pendingMessage(failed)],
          pending: [failed],
        });
      },
    },
    {
      name: "does not infer optimistic thinking from a user-ended transcript",
      text: "已经发送",
      thinking: false,
      build: () =>
        state({
          awaitingReply: true,
          locallyAwaitingReply: false,
          messages: [message("msg_user", "user", "已经发送")],
        }),
    },
    {
      name: "does not let the previous stopped snapshot hide a current local send",
      text: "开始吧",
      thinking: true,
      build: () =>
        state({
          awaitingReply: true,
          locallyAwaitingReply: true,
          messages: [
            message("pending:req_1", "user", "开始吧", {
              clientRequestId: "req_1",
              delivery: "sending",
              source: "pending",
            }),
          ],
          participantStatus: {
            conversationId: "cnv_1",
            participantId: "ptp_1",
            state: "stopped",
            status: "",
            updatedAt: 1_780_000_000_100,
          },
        }),
    },
  ])("$name", async ({ build, text, thinking }) => {
    renderStatefulConversation(build());

    expect(await screen.findByText(text)).toBeInTheDocument();
    if (thinking) {
      expect(screen.getByText("Thinking")).toBeInTheDocument();
    } else {
      expect(screen.queryByText("Thinking")).toBeNull();
    }
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "data-active",
      String(thinking)
    );
  });

  it("surfaces the specific failed send reason when one is available", () => {
    render(
      <ConversationThread
        messages={[
          message("pending:req_1", "user", "继续", {
            clientRequestId: "req_1",
            delivery: "failed",
            error: "额度不足",
            source: "pending",
          }),
        ]}
        onDiscard={() => {}}
        onRetry={() => {}}
        groupId="grp_1"
        workspaceId="wsp_1"
      />
    );

    expect(screen.getByTestId("chat-failed-row")).toHaveTextContent(
      "Send failed · 额度不足"
    );
  });
});

describe("Composer", () => {
  it("keeps IME composition local until the candidate is confirmed", () => {
    // WebKit delivers the confirming Enter after compositionend.
    const vendor = vi
      .spyOn(window.navigator, "vendor", "get")
      .mockReturnValue("Apple Computer, Inc.");
    const onDraftChange = vi.fn();
    const onSend = vi.fn();
    const view = render(
      <Composer
        draftSource={fixedDraftSource("你")}
        onDraftChange={onDraftChange}
        onSend={onSend}
        submitDisabled={false}
      />
    );
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    fireEvent.compositionStart(textbox);
    textbox.textContent = "ni";
    fireEvent.input(textbox, {
      data: "ni",
      inputType: "insertCompositionText",
      isComposing: true,
    });
    expect(onDraftChange).not.toHaveBeenCalled();
    fireEvent.keyDown(textbox, { key: "Enter", keyCode: 229 });
    expect(onSend).not.toHaveBeenCalled();

    textbox.textContent = "你";
    fireEvent.input(textbox, {
      data: "你",
      inputType: "insertCompositionText",
      isComposing: true,
    });
    fireEvent.compositionEnd(textbox);
    expect(onDraftChange).toHaveBeenCalledOnce();
    expect(onDraftChange).toHaveBeenCalledWith("你");
    fireEvent.keyDown(textbox, { key: "Enter" });
    expect(onSend).not.toHaveBeenCalled();

    // Only the one confirming keydown is swallowed; the next Enter sends.
    fireEvent.keyDown(textbox, { key: "Enter" });
    expect(onSend).toHaveBeenCalledWith("你", { skills: [] });

    view.unmount();
    vendor.mockRestore();
  });

  it("sends a Chromium Enter pressed right after the IME commits", () => {
    // Chromium flags the confirming key itself, so an Enter after
    // compositionend is a new press — e.g. Space commits "你好", then Enter.
    const vendor = vi
      .spyOn(window.navigator, "vendor", "get")
      .mockReturnValue("Google Inc.");
    const onSend = vi.fn();
    const view = render(
      <Composer
        draftSource={fixedDraftSource("你好")}
        onDraftChange={() => {}}
        onSend={onSend}
        submitDisabled={false}
      />
    );
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    fireEvent.compositionStart(textbox);
    fireEvent.keyDown(textbox, { key: " ", keyCode: 229, isComposing: true });
    fireEvent.compositionEnd(textbox, { data: "你好" });
    fireEvent.keyDown(textbox, { key: "Enter" });

    expect(onSend).toHaveBeenCalledWith("你好", { skills: [] });
    view.unmount();
    vendor.mockRestore();
  });

  it("guards Chromium IME Enter keyCode 229 and sends plain Enter", () => {
    const onSend = vi.fn();
    const onDraftChange = vi.fn();
    render(
      <Composer
        draftSource={fixedDraftSource("你好")}
        onDraftChange={onDraftChange}
        onSend={onSend}
        submitDisabled={false}
      />
    );
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    fireEvent.keyDown(textbox, { key: "Enter", keyCode: 229 });
    expect(onSend).not.toHaveBeenCalled();

    fireEvent.keyDown(textbox, { key: "Enter" });
    expect(onSend).toHaveBeenCalledWith("你好", { skills: [] });
  });

  it("does not mount attachment controls when the channel has no attachment action", () => {
    const view = render(
      <Composer
        draftSource={fixedDraftSource("")}
        onDraftChange={() => {}}
        onSend={() => {}}
        submitDisabled={false}
      />
    );

    expect(screen.queryByRole("button", { name: "Add attachment" })).toBeNull();
    expect(view.container.querySelector('input[type="file"]')).toBeNull();
    expect(screen.queryByTestId("ai-input-drop-overlay")).toBeNull();
    expect(screen.queryByRole("button", { name: "Full-access" })).toBeNull();
    expect(screen.queryByRole("button", { name: "Voice input" })).toBeNull();
    expect(screen.getByRole("button", { name: "Send message" })).toBeDisabled();
  });

  it("passes selected files to the channel attachment handler", () => {
    const onAttachFiles = vi.fn();
    const view = render(
      <Composer
        draftSource={fixedDraftSource("")}
        onAttachFiles={onAttachFiles}
        onDraftChange={() => {}}
        onSend={() => {}}
        submitDisabled={false}
      />
    );

    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }));
    const input = view.container.querySelector<HTMLInputElement>('input[type="file"]');
    expect(input).not.toBeNull();
    const file = new File(["hello"], "report.txt", { type: "text/plain" });
    fireEvent.change(input!, { target: { files: [file] } });

    expect(onAttachFiles).toHaveBeenCalledWith([
      { data: file, name: "report.txt", size: 5 },
    ]);
  });

  it("turns a HEIC away with guidance when the host cannot transcode it", async () => {
    const actions = createActions();
    render(<Toaster />);
    const rendered = renderStatefulConversation(state(), actions);

    // The toolbar button only opens this hidden input; drive it directly.
    const input = await waitFor(() => {
      const element =
        rendered.container.querySelector<HTMLInputElement>('input[type="file"]');
      expect(element).not.toBeNull();
      return element!;
    });
    const heic = new File(["heic"], "IMG_0001.HEIC", { type: "image/heic" });
    const png = new File(["png"], "shot.png", { type: "image/png" });
    fireEvent.change(input, { target: { files: [heic, png] } });

    expect(actions.attachFiles).toHaveBeenCalledWith([
      { data: png, name: "shot.png", size: 3 },
    ]);
    expect(await screen.findByTestId("chat-heic-unsupported")).toHaveTextContent(
      "This browser doesn't support processing .heic image files"
    );
  });

  it("hands a HEIC to the channel untouched when the host transcodes it", async () => {
    const actions = { ...createActions(), transcodesImages: true };
    const rendered = renderStatefulConversation(state(), actions);

    const input = await waitFor(() => {
      const element =
        rendered.container.querySelector<HTMLInputElement>('input[type="file"]');
      expect(element).not.toBeNull();
      return element!;
    });
    const heic = new File(["heic"], "IMG_0001.HEIC", { type: "image/heic" });
    fireEvent.change(input, { target: { files: [heic] } });

    expect(actions.attachFiles).toHaveBeenCalledWith([
      { data: heic, name: "IMG_0001.HEIC", size: 4 },
    ]);
    expect(screen.queryByTestId("chat-heic-unsupported")).toBeNull();
  });

  it.each([
    {
      name: "passes dropped files to the channel attachment handler",
      fileName: "dropped.txt",
      deliver: (file: File) =>
        fireEvent.drop(screen.getByTestId("ai-input-shell"), {
          dataTransfer: {
            types: ["Files"],
            files: [file],
          },
        }),
    },
    {
      name: "passes pasted files to the channel attachment handler",
      fileName: "pasted.txt",
      deliver: (file: File) =>
        fireEvent.paste(screen.getByRole("textbox", { name: "AI prompt" }), {
          clipboardData: {
            types: ["Files"],
            files: [file],
            getData: () => "pasted.txt",
          },
        }),
    },
  ])("$name", ({ deliver, fileName }) => {
    const onAttachFiles = vi.fn();
    render(
      <Composer
        draftSource={fixedDraftSource("")}
        onAttachFiles={onAttachFiles}
        onDraftChange={() => {}}
        onSend={() => {}}
        submitDisabled={false}
      />
    );

    const file = new File(["hello"], fileName, { type: "text/plain" });
    deliver(file);

    expect(onAttachFiles).toHaveBeenCalledWith([
      { data: file, name: fileName, size: 5 },
    ]);
  });

  it("leaves a text-only paste to the editor", () => {
    const onAttachFiles = vi.fn();
    const onDraftChange = vi.fn();
    render(
      <Composer
        draftSource={fixedDraftSource("")}
        onAttachFiles={onAttachFiles}
        onDraftChange={onDraftChange}
        onSend={() => {}}
        submitDisabled={false}
      />
    );

    const editor = screen.getByRole("textbox", { name: "AI prompt" });
    editor.focus();
    fireEvent.paste(editor, {
      clipboardData: {
        types: ["text/plain"],
        files: [],
        getData: () => "just text",
      },
    });

    expect(onAttachFiles).not.toHaveBeenCalled();
    expect(onDraftChange).toHaveBeenCalledWith("just text");
  });

  it("uses the native local-index picker when the channel provides it", () => {
    const onAttachFiles = vi.fn();
    const onPickAttachments = vi.fn();
    render(
      <Composer
        draftSource={fixedDraftSource("")}
        onAttachFiles={onAttachFiles}
        onDraftChange={vi.fn()}
        onPickAttachments={onPickAttachments}
        onSend={vi.fn()}
        submitDisabled={false}
      />
    );

    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }));

    expect(onPickAttachments).toHaveBeenCalledOnce();
    expect(onAttachFiles).not.toHaveBeenCalled();
  });

  it("keeps the side-chat attachment action left of a single line and moves it to the lower-left for multiline input", () => {
    const onAttachFiles = vi.fn();
    const view = render(
      <Composer
        draftSource={fixedDraftSource("")}
        onAttachFiles={onAttachFiles}
        onDraftChange={() => {}}
        onSend={() => {}}
        submitDisabled={false}
        variant="side-chat"
      />
    );

    const shell = view.container.querySelector<HTMLElement>(
      ".comma-chat-composer-shell"
    );
    const attachButton = screen.getByRole("button", { name: "Add attachment" });
    const leadingToolbar = attachButton.closest(
      '[data-slot="ai-input-toolbar-leading"]'
    );
    const trailingToolbar = view.container.querySelector<HTMLElement>(
      '[data-slot="ai-input-toolbar-trailing"]'
    );
    expect(shell).not.toHaveAttribute("data-side-chat-multiline");
    expect(leadingToolbar).not.toBeNull();
    expect(trailingToolbar).not.toBeNull();

    const input = view.container.querySelector<HTMLInputElement>('input[type="file"]');
    const file = new File(["hello"], "report.txt", { type: "text/plain" });
    fireEvent.change(input!, { target: { files: [file] } });
    expect(onAttachFiles).toHaveBeenCalledWith([
      { data: file, name: "report.txt", size: 5 },
    ]);

    const textbox = screen.getByRole("textbox", { name: "AI prompt" });
    const scrollHeight = vi
      .spyOn(HTMLElement.prototype, "scrollHeight", "get")
      .mockReturnValue(60);
    try {
      typeIntoComposerRichEditor(textbox, "第一行\n第二行");
    } finally {
      scrollHeight.mockRestore();
    }

    expect(shell).toHaveAttribute("data-side-chat-multiline", "true");
    expect(attachButton.closest('[data-slot="ai-input-toolbar-leading"]')).toBe(
      leadingToolbar
    );
  });

  it("allows sending uploaded attachments without a text draft", () => {
    const onSend = vi.fn();
    render(
      <Composer
        draftSource={fixedDraftSource("")}
        draftAttachments={[
          {
            error: undefined,
            id: "att_1",
            isImage: false,
            name: "report.txt",
            path: "/uploads/1-report.txt",
            size: 5,
            status: "uploaded",
          },
        ]}
        onDraftChange={() => {}}
        onSend={onSend}
        submitDisabled={false}
      />
    );

    fireEvent.click(screen.getByRole("button", { name: "Send message" }));
    expect(onSend).toHaveBeenCalledWith("", { skills: [] });
  });

  it("guards Safari compositionend before Enter within the 100ms window", () => {
    vi.useFakeTimers();
    const onSend = vi.fn();
    render(
      <Composer
        draftSource={fixedDraftSource("风险")}
        onDraftChange={() => {}}
        onSend={onSend}
        submitDisabled={false}
      />
    );
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    fireEvent.compositionEnd(textbox);
    fireEvent.keyDown(textbox, { key: "Enter" });
    expect(onSend).not.toHaveBeenCalled();

    vi.advanceTimersByTime(101);
    fireEvent.keyDown(textbox, { key: "Enter" });
    expect(onSend).toHaveBeenCalledWith("风险", { skills: [] });
    vi.useRealTimers();
  });

  it("preserves the focused editor and caret when workspace skills load", () => {
    const onDraftChange = vi.fn();
    const onSend = vi.fn();
    const renderComposer = (skills: CommaSkill[]) => (
      <Composer
        draftSource={fixedDraftSource("review this")}
        onDraftChange={onDraftChange}
        onSend={onSend}
        skills={skills}
        submitDisabled={false}
      />
    );
    const view = render(renderComposer([]));
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    setComposerCaret(textbox, 6);
    expect(textbox).toHaveFocus();
    expect(getComposerCaret(textbox)).toBe(6);

    view.rerender(renderComposer(composerSkills));
    const loadedTextbox = screen.getByRole("textbox", { name: "AI prompt" });

    expect(loadedTextbox).toBe(textbox);
    expect(loadedTextbox).toHaveFocus();
    expect(getComposerCaret(loadedTextbox)).toBe(6);
  });

  it("opens a skill menu, selects with keyboard, and submits selected skills", async () => {
    const onSend = vi.fn();
    render(<ComposerHarness onSend={onSend} skills={composerSkills} />);
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoComposerRichEditor(textbox, "你好 /");
    expect(screen.getByRole("listbox", { name: "Skills" })).toBeVisible();
    expect(screen.getAllByRole("option")).toHaveLength(2);

    fireEvent.keyDown(textbox, { key: "ArrowDown" });
    expect(screen.getByRole("option", { name: /Code Review/ })).toHaveAttribute(
      "aria-selected",
      "true"
    );

    fireEvent.keyDown(textbox, { key: "Enter" });
    expect(onSend).not.toHaveBeenCalled();
    await waitFor(() =>
      expect(textbox.querySelector("[data-ai-input-token]")).toHaveTextContent(
        "Code Review"
      )
    );

    fireEvent.keyDown(textbox, { key: "Enter" });
    expect(onSend).toHaveBeenCalledWith("你好 /code-review ", {
      skills: [{ location: "/.runtime/skills/code-review/SKILL.md" }],
    });
  });

  it("keeps menu keys out of IME confirmation and Escape closes without blur", () => {
    const onSend = vi.fn();
    render(<ComposerHarness onSend={onSend} skills={composerSkills} />);
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoComposerRichEditor(textbox, "/");
    expect(screen.getByRole("listbox", { name: "Skills" })).toBeVisible();

    fireEvent.keyDown(textbox, { key: "Enter", keyCode: 229 });
    expect(onSend).not.toHaveBeenCalled();
    expect(textbox).toHaveTextContent("/");

    fireEvent.keyDown(textbox, { key: "Escape" });
    expect(screen.queryByRole("listbox", { name: "Skills" })).toBeNull();
    fireEvent.keyDown(textbox, { key: "Enter" });
    expect(onSend).toHaveBeenCalledWith("/", { skills: [] });
  });

  it("inserts @plugin as a rich token while submitting its plain representation", () => {
    const onSend = vi.fn();
    render(
      <ComposerHarness
        mentionSources={{
          drive: { items: [], status: "ready" },
          plugins: {
            items: [{ id: "codex", name: "Codex", summary: "Write and review code" }],
            status: "ready",
          },
          routines: { items: [], status: "ready" },
          tasks: { items: [], status: "ready" },
        }}
        onSend={onSend}
        skills={[]}
      />
    );
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoComposerRichEditor(textbox, "Use @cod");
    expect(screen.getByRole("listbox", { name: "Mentions" })).toBeVisible();
    fireEvent.keyDown(textbox, { key: "Enter" });

    expect(textbox.querySelector("[data-ai-input-token]")).toHaveTextContent("Codex");
    fireEvent.keyDown(textbox, { key: "Enter" });
    expect(onSend).toHaveBeenCalledWith("Use @codex ", { skills: [] });
  });

  it("mentions a Task through @ and serializes it as an agent-readable link", () => {
    const onSend = vi.fn();
    render(
      <ComposerHarness
        mentionSources={{
          drive: { items: [], status: "ready" },
          plugins: { items: [], status: "ready" },
          routines: { items: [], status: "ready" },
          tasks: {
            items: [
              {
                conversationId: "cnv1_task123",
                statusBucket: "in_progress",
                title: "Fix login flow",
                updatedAt: 10,
              },
            ],
            status: "ready",
          },
        }}
        onSend={onSend}
        skills={[]}
      />
    );
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoComposerRichEditor(textbox, "Check @fix");
    expect(screen.getByRole("listbox", { name: "Mentions" })).toBeVisible();
    expect(screen.getByText("Tasks")).toBeVisible();
    fireEvent.keyDown(textbox, { key: "Enter" });

    expect(textbox.querySelector("[data-ai-input-token]")).toHaveTextContent(
      "Fix login flow"
    );
    fireEvent.keyDown(textbox, { key: "Enter" });
    expect(onSend).toHaveBeenCalledWith(
      "Check [Fix login flow](comma:task/cnv1_task123) ",
      { skills: [] }
    );
  });

  it("orders the @ menu Add, Tasks, Routines, Plugins, Drive", () => {
    const onAttachFiles = vi.fn();
    const blob = new Blob(["report"], { type: "application/pdf" });
    render(
      <ComposerHarness
        mentionSources={{
          drive: {
            items: [
              {
                file: {
                  contentsHash: "hash-report",
                  deviceId: "this-mac",
                  id: "drive-file-report",
                  modifiedAt: 30,
                  name: "report.pdf",
                  sizeBytes: blob.size,
                  spaceId: "space-a",
                },
                location: "Folder A",
                read: () => Promise.resolve(blob),
              },
            ],
            status: "ready",
          },
          plugins: { items: [{ id: "codex", name: "Codex" }], status: "ready" },
          routines: {
            items: [
              {
                href: "https://example.com/routines/daily",
                id: "routine-daily",
                kind: "link",
                label: "Daily digest",
              },
            ],
            status: "ready",
          },
          tasks: {
            items: [
              {
                conversationId: "cnv1_task123",
                statusBucket: "in_progress",
                title: "Fix login flow",
                updatedAt: 10,
              },
            ],
            status: "ready",
          },
        }}
        onAttachFiles={onAttachFiles}
        onSend={() => {}}
        skills={[]}
      />
    );
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoComposerRichEditor(textbox, "@");
    const list = screen.getByRole("listbox", { name: "Mentions" });
    const sections = within(list)
      .getAllByRole("group")
      .map((group) => group.firstElementChild?.textContent);
    expect(sections).toEqual(["Add", "Tasks", "Routines", "Plugins", "Drive"]);
  });

  it("answers / with the panel's No results state when no skills exist", () => {
    const onSend = vi.fn();
    render(<ComposerHarness onSend={onSend} skills={[]} />);
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoComposerRichEditor(textbox, "/");
    expect(screen.getByRole("listbox", { name: "Skills" })).toBeVisible();
    expect(screen.getByTestId("ai-input-menu-no-results")).toHaveTextContent(
      "No results"
    );
  });

  it("shows No results when an @ query matches nothing", () => {
    const onSend = vi.fn();
    render(
      <ComposerHarness
        mentionSources={{
          drive: { items: [], status: "ready" },
          plugins: { items: [], status: "ready" },
          routines: { items: [], status: "ready" },
          tasks: { items: [], status: "ready" },
        }}
        onSend={onSend}
        skills={[]}
      />
    );
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoComposerRichEditor(textbox, "@zzz");
    expect(screen.getByRole("listbox", { name: "Mentions" })).toBeVisible();
    expect(screen.getByTestId("ai-input-menu-no-results")).toHaveTextContent(
      "No results"
    );

    // Enter falls through to a normal submit when nothing is selectable.
    fireEvent.keyDown(textbox, { key: "Enter" });
    expect(onSend).toHaveBeenCalledWith("@zzz", { skills: [] });
  });

  it("scrolls keyboard-selected options into view but never hover-selected ones", () => {
    const scrollIntoView = vi.fn();
    const original = HTMLElement.prototype.scrollIntoView;
    HTMLElement.prototype.scrollIntoView = scrollIntoView;
    try {
      render(
        <ComposerHarness
          mentionSources={{
            drive: { items: [], status: "ready" },
            plugins: { items: [], status: "ready" },
            routines: { items: [], status: "ready" },
            tasks: {
              items: [
                {
                  conversationId: "cnv1_a",
                  statusBucket: "done",
                  title: "Alpha task",
                  updatedAt: 3,
                },
                {
                  conversationId: "cnv1_b",
                  statusBucket: "done",
                  title: "Beta task",
                  updatedAt: 2,
                },
                {
                  conversationId: "cnv1_c",
                  statusBucket: "done",
                  title: "Gamma task",
                  updatedAt: 1,
                },
              ],
              status: "ready",
            },
          }}
          onSend={vi.fn()}
          skills={[]}
        />
      );
      const textbox = screen.getByRole("textbox", { name: "AI prompt" });

      typeIntoComposerRichEditor(textbox, "@");
      expect(screen.getByRole("listbox", { name: "Mentions" })).toBeVisible();
      const baseline = scrollIntoView.mock.calls.length;

      // Actual pointer movement selects without scrolling; rows moving beneath
      // a stationary pointer do not select. Arrow keys still reveal their target.
      fireEvent.pointerMove(screen.getByRole("option", { name: /Beta task/ }), {
        pointerType: "mouse",
        clientX: 40,
        clientY: 80,
        movementX: 1,
        movementY: 1,
      });
      expect(screen.getByRole("option", { name: /Beta task/ })).toHaveAttribute(
        "aria-selected",
        "true"
      );
      expect(scrollIntoView.mock.calls.length).toBe(baseline);

      fireEvent.keyDown(textbox, { key: "ArrowDown" });
      expect(screen.getByRole("option", { name: /Gamma task/ })).toHaveAttribute(
        "aria-selected",
        "true"
      );
      expect(scrollIntoView.mock.calls.length).toBe(baseline + 1);
    } finally {
      HTMLElement.prototype.scrollIntoView = original;
    }
  });

  it("keeps the @ panel open and filtering through an IME composition", () => {
    const onSend = vi.fn();
    render(
      <ComposerHarness
        mentionSources={{
          drive: { items: [], status: "ready" },
          plugins: { items: [], status: "ready" },
          routines: { items: [], status: "ready" },
          tasks: {
            items: [
              {
                conversationId: "cnv1_zh",
                statusBucket: "in_progress",
                title: "翻译这句话",
                updatedAt: 20,
              },
              {
                conversationId: "cnv1_en",
                statusBucket: "done",
                title: "Fix login flow",
                updatedAt: 10,
              },
            ],
            status: "ready",
          },
        }}
        onSend={onSend}
        skills={[]}
      />
    );
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoComposerRichEditor(textbox, "@");
    expect(screen.getByRole("listbox", { name: "Mentions" })).toBeVisible();
    expect(screen.getAllByRole("option")).toHaveLength(2);

    // A CJK composition ("fan" → 翻) refines the query without closing the
    // panel; the editor value itself must not commit mid-composition.
    fireEvent.compositionStart(textbox);
    textbox.textContent = "@翻";
    setComposerCaret(textbox, 2);
    fireEvent.input(textbox, { data: "翻", inputType: "insertCompositionText" });

    const menu = screen.getByRole("listbox", { name: "Mentions" });
    expect(menu).toBeVisible();
    expect(screen.getByRole("option", { name: /翻译这句话/ })).toBeVisible();
    expect(screen.queryByRole("option", { name: /Fix login flow/ })).toBeNull();

    // Selection stays blocked while the composition is live.
    fireEvent.mouseDown(screen.getByRole("option", { name: /翻译这句话/ }));
    expect(textbox.querySelector("[data-ai-input-token]")).toBeNull();

    fireEvent.compositionEnd(textbox, { data: "翻" });
    expect(screen.getByRole("listbox", { name: "Mentions" })).toBeVisible();

    fireEvent.mouseDown(screen.getByRole("option", { name: /翻译这句话/ }));
    expect(textbox.querySelector("[data-ai-input-token]")).toHaveTextContent(
      "翻译这句话"
    );

    // Step past the IME confirmation window so Enter reads as a submit.
    const nowSpy = vi.spyOn(Date, "now").mockReturnValue(Date.now() + 200);
    try {
      fireEvent.keyDown(textbox, { key: "Enter" });
    } finally {
      nowSpy.mockRestore();
    }
    expect(onSend).toHaveBeenCalledWith("[翻译这句话](comma:task/cnv1_zh) ", {
      skills: [],
    });
  });

  it("triggers the menus from fullwidth ＠ and ／ and consumes the alias on select", () => {
    const onSend = vi.fn();
    render(
      <ComposerHarness
        mentionSources={{
          drive: { items: [], status: "ready" },
          plugins: { items: [], status: "ready" },
          routines: { items: [], status: "ready" },
          tasks: {
            items: [
              {
                conversationId: "cnv1_task123",
                statusBucket: "in_progress",
                title: "Fix login flow",
                updatedAt: 10,
              },
            ],
            status: "ready",
          },
        }}
        onSend={onSend}
        skills={composerSkills}
      />
    );
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoComposerRichEditor(textbox, "／code");
    expect(screen.getByRole("listbox", { name: "Skills" })).toBeVisible();

    typeIntoComposerRichEditor(textbox, "看 ＠fix");
    expect(screen.getByRole("listbox", { name: "Mentions" })).toBeVisible();
    fireEvent.keyDown(textbox, { key: "Enter" });

    expect(textbox.querySelector("[data-ai-input-token]")).toHaveTextContent(
      "Fix login flow"
    );
    fireEvent.keyDown(textbox, { key: "Enter" });
    // The fullwidth alias is replaced along with the query.
    expect(onSend).toHaveBeenCalledWith(
      "看 [Fix login flow](comma:task/cnv1_task123) ",
      {
        skills: [],
      }
    );
  });

  it("shows the shimmer searching row while @ sources are indexing", () => {
    const onSend = vi.fn();
    render(
      <ComposerHarness
        mentionSources={{
          drive: { items: [], status: "ready" },
          plugins: { items: [], status: "loading" },
          routines: { items: [], status: "loading" },
          tasks: { items: [], status: "loading" },
        }}
        onSend={onSend}
        skills={[]}
      />
    );
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoComposerRichEditor(textbox, "@");
    expect(screen.getByRole("listbox", { name: "Mentions" })).toBeVisible();
    expect(screen.getByTestId("ai-input-menu-searching")).toHaveTextContent(
      "Searching..."
    );
  });
});

const composerSkills: CommaSkill[] = [
  {
    skill_id: "weekly-summary",
    name: "Weekly Summary",
    description: "Summarize meetings",
    location: "/.runtime/skills/weekly-summary/SKILL.md",
  },
  {
    skill_id: "code-review",
    name: "Code Review",
    description: "Review pull requests",
    location: "/.runtime/skills/code-review/SKILL.md",
  },
];

function ComposerHarness({
  mentionSources,
  onAttachFiles,
  onSend,
  skills,
}: {
  mentionSources?: ComposerMentionSources;
  onAttachFiles?: (files: AttachmentUploadInput[]) => void;
  onSend: (draft: string, options: { skills: { location: string }[] }) => void;
  skills: CommaSkill[];
}) {
  const [draft, setDraft] = useState("");
  return (
    <Composer
      draftSource={fixedDraftSource(draft)}
      {...(mentionSources ? { mentionSources } : {})}
      {...(onAttachFiles ? { onAttachFiles } : {})}
      onDraftChange={setDraft}
      onSend={onSend}
      skills={skills}
      submitDisabled={false}
    />
  );
}

function typeIntoComposerRichEditor(editor: HTMLElement, text: string) {
  editor.textContent = text;
  const textNode = editor.firstChild;
  if (!textNode) throw new Error("expected composer editor text node");
  const range = document.createRange();
  range.setStart(textNode, text.length);
  range.collapse(true);
  const selection = window.getSelection();
  selection?.removeAllRanges();
  selection?.addRange(range);
  fireEvent.input(editor, { inputType: "insertText", data: text.at(-1) });
}

function setComposerCaret(editor: HTMLElement, offset: number) {
  editor.focus();
  if (editor instanceof HTMLTextAreaElement) {
    editor.setSelectionRange(offset, offset);
    return;
  }

  const textNode = editor.firstChild;
  if (!textNode) throw new Error("expected composer editor text node");
  const range = document.createRange();
  range.setStart(textNode, offset);
  range.collapse(true);
  const selection = window.getSelection();
  selection?.removeAllRanges();
  selection?.addRange(range);
}

function getComposerCaret(editor: HTMLElement) {
  if (editor instanceof HTMLTextAreaElement) {
    return editor.selectionStart;
  }

  const selection = window.getSelection();
  if (!selection || selection.rangeCount === 0) return null;
  const range = selection.getRangeAt(0).cloneRange();
  const prefix = range.cloneRange();
  prefix.selectNodeContents(editor);
  prefix.setEnd(range.endContainer, range.endOffset);
  return prefix.toString().length;
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

function PlainPromiseFailureHarness({
  onFailureReady,
}: {
  onFailureReady: (fail: () => void) => void;
}) {
  const [viewState, setViewState] = useState(
    state({ draft: "Fail after local acceptance", messages: [] })
  );
  const actions: ConversationViewActions = {
    attachFiles: vi.fn(),
    discard: vi.fn(),
    refresh: vi.fn(),
    removeAttachment: vi.fn(),
    retry: vi.fn(),
    retryAttachment: vi.fn(),
    send: (text) => {
      const pending = pendingSend("req_web_failure", text, "sending");
      setViewState((current) =>
        state({
          ...current,
          awaitingReply: true,
          awaitingSince: Date.now(),
          awaitingTurnKey: pending.clientRequestId,
          draft: "",
          messages: [pendingMessage(pending)],
          pending: [pending],
        })
      );

      let rejectCompletion!: (error: Error) => void;
      const completion = new Promise<never>((_resolve, reject) => {
        rejectCompletion = reject;
      });
      void completion.catch(() => undefined);
      onFailureReady(() => {
        const failed = {
          ...pending,
          error: "Billing is temporarily unavailable. Try again later.",
          status: "failed" as const,
        };
        setViewState((current) =>
          state({
            ...current,
            awaitingReply: false,
            awaitingSince: undefined,
            messages: [pendingMessage(failed)],
            pending: [failed],
          })
        );
        rejectCompletion(new Error("billing_unavailable"));
      });
      return completion;
    },
    setDraft: (draft) => setViewState((current) => ({ ...current, draft })),
  };

  return (
    <ConversationViewWithDraft
      actions={actions}
      state={viewState}
      variant="side-chat"
      groupId="grp_1"
      workspaceId="wsp_1"
    />
  );
}

function SideChatSendLifecycleHarness({ onSend }: { onSend: (text: string) => void }) {
  const [viewState, setViewState] = useState(
    state({ draft: "Ship renderer parity", messages: [] })
  );
  const actions: ConversationViewActions = {
    attachFiles: vi.fn(),
    discard: vi.fn(),
    refresh: vi.fn(),
    removeAttachment: vi.fn(),
    retry: vi.fn(),
    retryAttachment: vi.fn(),
    send: (text) => {
      onSend(text);
      setViewState((current) => {
        const pending = pendingSend(
          `req_side_chat_${current.pending.length + 1}`,
          text,
          "sending"
        );
        return state({
          ...current,
          awaitingReply: true,
          awaitingSince: current.awaitingSince ?? Date.now(),
          awaitingTurnKey: pending.clientRequestId,
          draft: "",
          messages: [...current.messages, pendingMessage(pending)],
          pending: [...current.pending, pending],
        });
      });
    },
    setDraft: (draft) => setViewState((current) => ({ ...current, draft })),
  };

  return (
    <ConversationViewWithDraft
      actions={actions}
      state={viewState}
      variant="side-chat"
      groupId="grp_1"
      workspaceId="wsp_1"
    />
  );
}

function SideChatStreamingLifecycleHarness({
  onDraftChange,
  onSend,
}: {
  onDraftChange: (draft: string) => void;
  onSend: (text: string, options?: { skills?: { location: string }[] }) => void;
}) {
  const [viewState, setViewState] = useState(
    state({
      assistantDraft: {
        conversationId: "cnv_1",
        draftId: "draft_streaming",
        responseKey: "rsp_streaming",
        sourceMessageIds: ["msg_streaming_user"],
        status: "streaming",
        text: "Streaming answer",
      },
      awaitingReply: false,
      draft: "Another thought",
      messages: [message("msg_streaming_user", "user", "Prompt")],
    })
  );
  const actions: ConversationViewActions = {
    attachFiles: vi.fn(),
    discard: vi.fn(),
    refresh: vi.fn(),
    removeAttachment: vi.fn(),
    retry: vi.fn(),
    retryAttachment: vi.fn(),
    send: (text, options) => {
      onSend(text, options);
      setViewState((current) => ({ ...current, draft: "" }));
    },
    setDraft: (draft) => {
      onDraftChange(draft);
      setViewState((current) => ({ ...current, draft }));
    },
  };

  return (
    <ConversationViewWithDraft
      actions={actions}
      state={viewState}
      variant="side-chat"
      groupId="grp_1"
      workspaceId="wsp_1"
    />
  );
}

function failedImageAttachment(id: string, name: string) {
  return {
    error: "Reconnect this workspace's Comma Connector.",
    id,
    isImage: true,
    name,
    path: undefined,
    size: 1_024,
    status: "failed" as const,
  };
}

function renderConversation(element: ReactElement) {
  const rootRoute = createRootRoute({
    component: Outlet,
  });
  const conversationRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/",
    component: () => element,
  });
  const inboxRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/inbox",
    component: () => null,
  });
  const targetConversationRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/inbox/$workspaceId/$groupId/$conversationId",
    component: TargetConversationRoute,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([
      conversationRoute,
      inboxRoute,
      targetConversationRoute,
    ]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });

  return render(
    <>
      <RouterProvider router={router} />
      <Toaster />
    </>
  );
}

function TargetConversationRoute() {
  return <div data-testid="routed-conversation">cnv_task</div>;
}

function renderStatefulConversation(
  initialState: ConversationChannelState,
  actions = createActions(),
  variant: "home" | "rail" | "route" | "side-chat" = "route"
) {
  let setViewState: ((next: ConversationChannelState) => void) | undefined;

  function RouteComponent() {
    const [viewState, setState] = useState(initialState);
    setViewState = setState;
    return (
      <ConversationViewWithDraft
        actions={actions}
        state={viewState}
        variant={variant}
      />
    );
  }

  const rootRoute = createRootRoute({
    component: Outlet,
  });
  const conversationRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/",
    component: RouteComponent,
  });
  const inboxRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/inbox",
    component: () => null,
  });
  const targetConversationRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/inbox/$workspaceId/$groupId/$conversationId",
    component: () => null,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([
      conversationRoute,
      inboxRoute,
      targetConversationRoute,
    ]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });

  return {
    ...render(<RouterProvider router={router} />),
    setState: (next: ConversationChannelState) => {
      if (!setViewState) {
        throw new Error("Conversation route did not render.");
      }
      setViewState(next);
    },
  };
}

function setElementMetric(
  element: HTMLElement,
  key: "clientHeight" | "clientWidth" | "scrollHeight",
  value: number
) {
  Object.defineProperty(element, key, {
    configurable: true,
    value,
  });
}

function elementRect(top: number): DOMRect {
  return {
    bottom: top,
    height: 0,
    left: 0,
    right: 0,
    toJSON: () => ({}),
    top,
    width: 0,
    x: 0,
    y: top,
  };
}

async function waitForNamedImageSrc(name: string, src: string) {
  await waitFor(() => {
    const match = screen
      .getAllByRole("img", { name })
      .find((image) => image.getAttribute("src") === src);
    expect(match).toBeTruthy();
  });
}

function sizedElementRect(top: number, height: number): DOMRect {
  return {
    bottom: top + height,
    height,
    left: 0,
    right: 320,
    toJSON: () => ({}),
    top,
    width: 320,
    x: 0,
    y: top,
  };
}

function mockOutgoingBubbleGeometry() {
  const original = HTMLElement.prototype.getBoundingClientRect;
  return vi
    .spyOn(HTMLElement.prototype, "getBoundingClientRect")
    .mockImplementation(function (this: HTMLElement) {
      if (this.classList.contains("comma-chat-user-bubble")) {
        return {
          bottom: 264,
          height: 64,
          left: 400,
          right: 620,
          toJSON: () => ({}),
          top: 200,
          width: 220,
          x: 400,
          y: 200,
        };
      }
      return original.call(this);
    });
}

function queryViewport(container: HTMLElement) {
  const viewport = container.querySelector<HTMLElement>(
    '[data-slot="scroll-area-viewport"]'
  );
  expect(viewport).not.toBeNull();
  return viewport!;
}

function containerArticle(container: HTMLElement, messageId: string) {
  const article = container.querySelector<HTMLElement>(
    `[data-message-id="${messageId}"]`
  );
  expect(article).not.toBeNull();
  return article!;
}

function state(overrides: Partial<ConversationChannelState> = {}) {
  const value: ConversationChannelState = {
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
      title: "整理本周会议纪要为周报",
      status: "completed",
    },
    draft: "",
    draftAttachments: [],
    errorKind: undefined,
    lastBackoffMs: 0,
    messages: [],
    pending: [],
    participantStatus: undefined,
    serverMessages: [],
    status: "ready",
    syncWarning: undefined,
    ...overrides,
  };
  const lastUser = value.messages.findLast((item) => item.role === "user");
  const awaitingTurnKey = lastUser
    ? (lastUser.clientRequestId ?? lastUser.messageId)
    : undefined;

  if (value.awaitingReply && value.awaitingTurnKey === undefined) {
    value.awaitingTurnKey = awaitingTurnKey;
  }

  if (value.activity) {
    const sourceMessageIds =
      value.activity.sourceMessageIds ??
      value.assistantDraft?.sourceMessageIds ??
      (lastUser ? [lastUser.messageId] : []);
    const responseKey =
      value.activity.responseKey ?? value.assistantDraft?.responseKey ?? "rsp-test";
    if (sourceMessageIds.length > 0) {
      value.activity = {
        ownerTurnKey:
          value.activity.ownerTurnKey ??
          initialResponseOwnerTurnKey(
            value.messages,
            visibleReplyIdentityKey(responseKey, sourceMessageIds),
            sourceMessageIds
          ),
        producerEpoch: value.activity.producerEpoch ?? "epoch-test",
        responseKey,
        sequence: value.activity.sequence ?? 1,
        sourceMessageIds,
        streamIncarnation: value.activity.streamIncarnation ?? 1,
        ...value.activity,
      };
    }
  }

  return value;
}

function burstAssistantDraft(text: string, status: "streaming" | "completed") {
  return {
    conversationId: "cnv_1",
    draftId: "draft_burst",
    responseKey: "rsp_burst",
    sourceMessageIds: ["msg_burst_user"],
    status,
    text,
  };
}

function pendingSend(
  clientRequestId: string,
  text: string,
  status: PendingSend["status"]
): PendingSend {
  return {
    clientRequestId,
    createdAt: 1,
    error: "offline",
    skills: undefined,
    status,
    text,
  };
}

function pendingMessage(pending: PendingSend): ChatMessage {
  return {
    attachments: [],
    blocksKey: undefined,
    clientRequestId: pending.clientRequestId,
    createdAt: pending.createdAt,
    createdBy: undefined,
    delivery: pending.status === "failed" ? "failed" : "sending",
    error: pending.error,
    failureAction: pending.failureAction,
    messageId: `pending:${pending.clientRequestId}`,
    parts: [{ kind: "markdown", text: pending.text }],
    refs: [],
    role: "user",
    source: "pending",
    status: pending.status,
    text: pending.text,
  };
}

function historyTurns(count: number): ChatMessage[] {
  return Array.from({ length: count }, (_, index) =>
    message(`msg_hist_${index}`, "user", `round ${index}`)
  );
}

function mockScrollport(
  element: HTMLElement,
  metrics: { clientHeight: number; scrollHeight: number; scrollTop: number }
) {
  Object.defineProperty(element, "clientHeight", {
    configurable: true,
    get: () => metrics.clientHeight,
  });
  Object.defineProperty(element, "scrollHeight", {
    configurable: true,
    get: () => metrics.scrollHeight,
  });
  Object.defineProperty(element, "scrollTop", {
    configurable: true,
    value: metrics.scrollTop,
    writable: true,
  });
}

function message(
  messageId: string,
  role: string,
  text: string,
  overrides: Partial<ChatMessage> = {}
): ChatMessage {
  const base: ChatMessage = {
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
  };
  return { ...base, ...overrides, parts: overrides.parts ?? base.parts };
}

const selectionActionBar = () =>
  document.querySelector('[data-slot="selection-action-bar"]');

/** Selects `[start, end)` of an element's first text node and settles it. */
function selectChatText(
  element: HTMLElement,
  start: number,
  end: number,
  options: { backward?: boolean; clickCount?: number } = {}
) {
  const textNode = element.firstChild;
  if (!textNode) throw new Error("expected a text node to select");
  const selection = window.getSelection();
  selection?.removeAllRanges();
  // A backward sweep ends where it began, so anchor and focus swap.
  if (options.backward) {
    selection?.setBaseAndExtent(textNode, end, textNode, start);
  } else {
    const range = document.createRange();
    range.setStart(textNode, start);
    range.setEnd(textNode, end);
    selection?.addRange(range);
  }
  if (options.clickCount) {
    fireEvent.mouseDown(element, { detail: options.clickCount });
  }
  // The bar waits for a settled gesture rather than the selectionchange stream.
  fireEvent.pointerUp(document);
}

function domRect(x: number, y: number, width: number, height: number): DOMRect {
  return {
    bottom: y + height,
    height,
    left: x,
    right: x + width,
    toJSON: () => ({}),
    top: y,
    width,
    x,
    y,
  } as DOMRect;
}

function localImageAttachment(index: number): ChatMessage["attachments"][number] {
  const refCharacter = String.fromCharCode("a".charCodeAt(0) + index);
  return {
    blockType: "image",
    fileName: `image-${index + 1}.png`,
    localFileRef: `lfi1_${refCharacter.repeat(43)}`,
    mimeType: "image/png",
    size: 456 + index,
    title: undefined,
  };
}

function installIntersectionObserverHarness() {
  type ObserverBand = "inner" | "outer";
  type ObserverRecord = {
    callback: IntersectionObserverCallback;
    observed: Set<Element>;
  };
  const observers = new Map<ObserverBand, ObserverRecord>();

  class TestIntersectionObserver {
    readonly record: ObserverRecord;

    constructor(
      nextCallback: IntersectionObserverCallback,
      options?: IntersectionObserverInit
    ) {
      const band =
        options?.rootMargin === "240px 0px"
          ? "inner"
          : options?.rootMargin === "720px 0px"
            ? "outer"
            : undefined;
      if (!band) {
        throw new Error(
          `Unexpected preview observer root margin: ${options?.rootMargin}`
        );
      }
      if (
        !(options?.root instanceof Element) ||
        options.root.getAttribute("data-slot") !== "scroll-area-viewport"
      ) {
        throw new Error("Preview observers must be rooted at the chat scrollport.");
      }
      this.record = { callback: nextCallback, observed: new Set() };
      observers.set(band, this.record);
    }

    disconnect() {
      this.record.observed.clear();
    }

    observe(element: Element) {
      this.record.observed.add(element);
    }

    unobserve(element: Element) {
      this.record.observed.delete(element);
    }
  }

  vi.stubGlobal(
    "IntersectionObserver",
    TestIntersectionObserver as unknown as typeof IntersectionObserver
  );

  return {
    firstObserved(band: ObserverBand = "inner") {
      const element = observers.get(band)?.observed.values().next().value;
      if (!(element instanceof Element)) {
        throw new Error(`Preview ${band} observer was not installed.`);
      }
      return element;
    },
    notify(band: ObserverBand, target: Element, isIntersecting: boolean) {
      const observer = observers.get(band);
      if (!observer) {
        throw new Error(`Preview ${band} observer callback is unavailable.`);
      }
      act(() => {
        observer.callback(
          [
            {
              intersectionRatio: isIntersecting ? 1 : 0,
              isIntersecting,
              target,
            } as IntersectionObserverEntry,
          ],
          {} as IntersectionObserver
        );
      });
    },
  };
}

describe("Composer Drive mentions", () => {
  it("lists the newest Drive files with View more and attaches a chosen file", async () => {
    const onAttachFiles = vi.fn();
    const onSend = vi.fn();
    const blob = new Blob(["report"], { type: "application/pdf" });
    const file = {
      contentsHash: "hash-report",
      deviceId: "this-mac",
      id: "drive-file-report",
      modifiedAt: 30,
      name: "report.pdf",
      sizeBytes: blob.size,
      spaceId: "space-a",
    };
    const read = vi.fn(() => Promise.resolve(blob));
    render(
      <ComposerHarness
        mentionSources={{
          drive: {
            items: [
              { file, location: "Folder A", read },
              {
                file: {
                  ...file,
                  id: "drive-file-older",
                  modifiedAt: 10,
                  name: "older.txt",
                },
                location: "Folder A / archive",
                read,
              },
            ],
            status: "ready",
          },
          plugins: { items: [], status: "ready" },
          routines: { items: [], status: "ready" },
          tasks: { items: [], status: "ready" },
        }}
        onAttachFiles={onAttachFiles}
        onSend={onSend}
        skills={[]}
      />
    );
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });

    typeIntoComposerRichEditor(textbox, "@");
    const list = screen.getByRole("listbox", { name: "Mentions" });
    const options = within(list)
      .getAllByRole("option")
      .map((option) => option.textContent);
    expect(options).toEqual([
      "Add files or folders",
      "report.pdfFolder A",
      "older.txtFolder A / archive",
      "View more",
    ]);

    // ArrowDown past Add lands on the newest file; Enter attaches it.
    fireEvent.keyDown(textbox, { key: "ArrowDown" });
    fireEvent.keyDown(textbox, { key: "Enter" });
    await waitFor(() =>
      expect(onAttachFiles).toHaveBeenCalledWith([
        { data: blob, name: "report.pdf", size: blob.size },
      ])
    );
    expect(read).toHaveBeenCalledTimes(1);
    // Attaching leaves no trigger text and no token behind.
    expect(textbox).toHaveTextContent("");
    expect(screen.queryByRole("listbox", { name: "Mentions" })).toBeNull();
  });

  it("keeps the Drive section out when nothing can be attached", () => {
    render(
      <ComposerHarness
        mentionSources={{
          drive: { items: [], status: "ready" },
          plugins: { items: [], status: "ready" },
          routines: { items: [], status: "ready" },
          tasks: { items: [], status: "ready" },
        }}
        onSend={() => {}}
        skills={[]}
      />
    );
    const textbox = screen.getByRole("textbox", { name: "AI prompt" });
    typeIntoComposerRichEditor(textbox, "@");
    expect(screen.queryByRole("option", { name: "View more" })).toBeNull();
  });
});

/** The view fed the draft its state names, the way a channel host feeds it. */
function ConversationViewWithDraft({
  state: channelState,
  ...props
}: Omit<ComponentProps<typeof ConversationView>, "draftSource" | "state"> & {
  state: ConversationChannelState;
}) {
  const draftSource = useMemo(
    () => fixedDraftSource(channelState.draft),
    [channelState.draft]
  );
  return <ConversationView {...props} draftSource={draftSource} state={channelState} />;
}
