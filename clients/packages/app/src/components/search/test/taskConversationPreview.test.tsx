import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import userEvent, { PointerEventsCheckLevel } from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ReactNode } from "react";
import type { CommaConversation, SalixMessage } from "@comma/core/api-schemas";
import { CONVERSATION_TURN_WINDOW } from "../../chat/thread/navigation/conversationTurnWindow";
import { TaskConversationPreview } from "../TaskConversationPreview";
import { normalizeUnixTimestampMs } from "../normalizeUnixTimestampMs";
import {
  TASK_PREVIEW_SEARCH_HIGHLIGHT,
  TASK_PREVIEW_SEARCH_HIGHLIGHT_OVERLAY,
  TASK_PREVIEW_SEARCH_HIGHLIGHT_RECT,
} from "../previewSearchHighlight";
import type { TaskConversationPreviewTarget } from "../taskConversationPreviewLoader";
import type { TaskConversationValue } from "@comma/core-client";
import { normalizeServerMessages } from "@comma/core/chat";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { stubProperty } from "@comma/test-utils/stub-property";

const FakeHighlight = class extends Set<AbstractRange> {
  constructor(...ranges: Range[]) {
    super(ranges);
  }
};
const previewHighlightRegistry = new Map<string, Highlight>();

beforeEach(() => {
  stubProperty(window, "Highlight", {
    configurable: true,
    value: FakeHighlight,
  });
  stubProperty(CSS, "highlights", {
    configurable: true,
    value: previewHighlightRegistry,
  });
});

afterEach(() => {
  previewHighlightRegistry.clear();
});

describe("task conversation preview", () => {
  it.each([
    [1_788_177_000, 1_788_177_000_000],
    [1_788_177_000_000, 1_788_177_000_000],
    [undefined, undefined],
    [Number.NaN, undefined],
    [Number.POSITIVE_INFINITY, undefined],
  ])("normalizes Unix timestamp %s to milliseconds %s", (timestamp, expected) => {
    expect(normalizeUnixTimestampMs(timestamp)).toBe(expected);
  });

  it("projects the complete visible canonical snapshot", () => {
    const visible = Array.from({ length: 14 }, (_, index) =>
      message(`message-${index + 1}`, index % 2 === 0 ? "user" : "assistant")
    );
    const projected = conversation("task-projection", [
      {
        ...message("private", "assistant"),
        content: [{ text: "[[comma-context]]\nsecret", type: "text" }],
      },
      ...visible,
      {
        ...message("protocol", "assistant"),
        content: [
          {
            text: "Visible answer\n[[comma-protocol]]\nprivate routing data",
            type: "text",
          },
        ],
      },
    ]);
    // The core projects a preview's messages as a channel does (`taskConversation`).
    const result = {
      messages: normalizeServerMessages(projected.messages ?? [], [], projected.kind),
    };

    expect(result.messages).toHaveLength(15);
    expect(result.messages[0]?.messageId).toBe("message-1");
    expect(result.messages.at(-1)?.text).toBe("Visible answer");
    expect(result.messages.some((item) => item.messageId === "private")).toBe(false);
  });

  it("mounts the canonical tail first and reveals older turns on upward scroll", async () => {
    const history = Array.from({ length: 14 }, (_, index) => ({
      ...message(`history-${index + 1}`, "user"),
      content: [{ text: `History ${index + 1}`, type: "text" }],
    }));
    const pollConversation = vi.fn<PollConversation>(async () => ({
      conversation: conversation("windowed", history),
      notModified: false,
    }));
    installPreviewCore(pollConversation);
    const view = renderPreview(
      <div className="h-[400px] w-[300px]">
        <TaskConversationPreview searchQuery="History" task={target("windowed")} />
      </div>
    );
    const thread = await waitFor(() => {
      const element = view.container.querySelector(".comma-chat-thread");
      expect(element).toBeTruthy();
      return element!;
    });

    expect(thread).toHaveAttribute(
      "data-comma-hidden-older-count",
      String(14 - CONVERSATION_TURN_WINDOW.initialTurns)
    );
    expect(view.container.querySelector('[data-message-id="history-1"]')).toBeNull();
    expect(
      view.container.querySelector('[data-message-id="history-14"]')
    ).not.toBeNull();
    await waitFor(() => expect(previewHighlightRanges()).toHaveLength(6));

    const viewport = view.container.querySelector<HTMLElement>(
      '[data-slot="scroll-area-viewport"]'
    )!;
    mockScrollport(viewport, {
      clientHeight: 480,
      scrollHeight: 2_400,
      scrollTop: 0,
    });
    fireEvent.wheel(viewport, { deltaY: -120 });
    fireEvent.scroll(viewport);

    await waitFor(() =>
      expect(thread).toHaveAttribute("data-comma-hidden-older-count", "0")
    );
    expect(
      view.container.querySelector('[data-message-id="history-1"]')
    ).not.toBeNull();
    await waitFor(() => expect(previewHighlightRanges()).toHaveLength(14));
  });

  it("renders the embedded assistant transcript as markdown", async () => {
    const pollConversation = vi.fn<PollConversation>(async () => ({
      conversation: conversation("markdown", [
        {
          ...message("markdown-answer", "assistant"),
          content: [
            {
              text: [
                "**Forecast risk**",
                "",
                "- Renewal timing",
                "- EMEA conversion",
                "",
                "[Open source](https://example.com/forecast)",
              ].join("\n"),
              type: "text",
            },
          ],
        },
      ]),
      notModified: false,
    }));

    installPreviewCore(pollConversation);
    const view = renderPreview(
      <div className="h-[400px] w-[451px]">
        <TaskConversationPreview task={target("markdown")} />
      </div>
    );

    await waitFor(() =>
      expect(view.container.querySelector("strong")).toHaveTextContent("Forecast risk")
    );
    expect(view.container.querySelectorAll("li")).toHaveLength(2);
    expect(view.container.querySelector("a")).toHaveAttribute(
      "href",
      "https://example.com/forecast"
    );
    const thread = view.container.querySelector(".comma-chat-thread");
    const viewport = view.container.querySelector('[data-slot="scroll-area-viewport"]');
    expect(thread).toHaveAttribute("data-content-mode", "display-only");
    expect(thread).toHaveAttribute("inert");
    expect(viewport).toHaveAttribute("aria-hidden", "true");
    expect(viewport).toHaveAttribute("tabindex", "-1");
    expect(
      view.container.querySelector('[data-slot="task-conversation-preview-thread"]')
    ).toHaveAttribute("data-variant", "command-preview");
    expect(
      view.container.querySelector('[data-slot="task-conversation-preview"]')
    ).toHaveClass(
      "border-[length:var(--border-width-0-5)]",
      "bg-popup-secondary",
      "shadow-lg"
    );
    expect(view.container.querySelector(".comma-chat-message-actions")).toBeNull();
  });

  it.each([true, false])(
    "keeps file metadata without inline downloads in task previews (blob: %s)",
    async (hasBlob) => {
      const pollConversation = vi.fn<PollConversation>(async () => ({
        conversation: conversation("attachment-task", [
          {
            ...message("attachment-message", "assistant"),
            content: [
              { type: "text", text: "Here is the report." },
              {
                // The endpoint addresses canonical block position, not this hint.
                attachment_index: 2,
                ...(hasBlob
                  ? {
                      blob_ref: {
                        kind: "blob",
                        uuid: "a".repeat(32),
                        hash: "b".repeat(64),
                        size: 2_048,
                      },
                    }
                  : {}),
                file_name: "report.pdf",
                mime_type: "application/pdf",
                size: 2_048,
                title: "report.pdf",
                type: "file",
              },
            ],
          },
        ]),
        notModified: false,
      }));
      installPreviewCore(pollConversation);

      renderPreview(
        <div className="h-[400px] w-[451px]">
          <TaskConversationPreview task={target("attachment-task")} />
        </div>
      );

      const fileCard = await screen.findByTestId(
        "chat-attachment-file-attachment-message-0"
      );
      expect(fileCard).toHaveTextContent("report.pdf");
      expect(
        within(fileCard).queryByRole("button", { name: "Download" })
      ).not.toBeInTheDocument();
      // File bytes never load for a passive card.
      expect(currentCore!.sentTo("files.read")).toEqual([]);
    }
  );

  it("keeps inline Tasks passive without loading a hover preview", async () => {
    const pollConversation = vi.fn<PollConversation>(async () => ({
      conversation: conversation("inline-task", [
        {
          ...message("inline-task-answer", "assistant"),
          content: [
            { text: "Created ", type: "text" },
            {
              conversation_id: "related-task",
              kind: "agent_task",
              presentation: "inline",
              status: "completed",
              title: "Related task",
              type: "conversation_ref",
            },
            { text: ".", type: "text" },
          ],
        },
      ]),
      notModified: false,
    }));
    installPreviewCore(pollConversation);
    const user = userEvent.setup({
      pointerEventsCheck: PointerEventsCheckLevel.Never,
    });

    renderPreview(
      <div className="h-[400px] w-[451px]">
        <TaskConversationPreview task={target("inline-task")} />
      </div>
    );

    const inlineTask = await screen.findByTestId("chat-inline-task-related-task");
    await user.hover(inlineTask);

    expect(screen.queryByRole("tooltip")).toBeNull();
    expect(document.querySelector('[data-slot="hover-card"]')).toBeNull();
    expect(currentCore!.topics).not.toContain("taskPreview");
  });

  it("highlights every rendered message match without changing markdown DOM", async () => {
    const pollConversation = vi.fn<PollConversation>(async () => ({
      conversation: conversation("highlighted", [
        {
          ...message("highlight-user", "user"),
          content: [{ text: "notion from user", type: "text" }],
        },
        {
          ...message("highlight-assistant", "assistant"),
          content: [
            {
              text: "Notion, **notion**, [No**tion** link](https://example.com/notion), `NOTION`, and Archive.",
              type: "text",
            },
          ],
        },
      ]),
      notModified: false,
    }));
    installPreviewCore(pollConversation);
    const previewTask = { ...target("highlighted"), title: "Notion title" };
    const view = renderPreview(
      <div className="h-[400px] w-[451px]">
        <TaskConversationPreview searchQuery="notion" task={previewTask} />
      </div>
    );

    const link = await waitFor(() => {
      const element = view.container.querySelector("a");
      expect(element).not.toBeNull();
      return element!;
    });
    await waitFor(() => expect(previewHighlightRanges()).toHaveLength(5));

    const notionRanges = previewHighlightRanges();
    expect(notionRanges.map((range) => range.toString().toLocaleLowerCase())).toEqual(
      Array.from({ length: 5 }, () => "notion")
    );
    expect(
      notionRanges.some((range) => range.startContainer !== range.endContainer)
    ).toBe(true);
    const title = view.container.querySelector("h2")!;
    expect(notionRanges.some((range) => title.contains(range.startContainer))).toBe(
      false
    );
    expect(link).toHaveAttribute("href", "https://example.com/notion");
    expect(view.container.querySelector("code")).toHaveTextContent("NOTION");
    expect(view.container.querySelector("mark")).toBeNull();

    view.rerender(
      currentCore!.wrap(
        <div className="h-[400px] w-[451px]">
          <TaskConversationPreview searchQuery="archive" task={previewTask} />
        </div>
      )
    );
    await waitFor(() =>
      expect(previewHighlightRanges().map((range) => range.toString())).toEqual([
        "Archive",
      ])
    );
    expect(pollConversation).toHaveBeenCalledOnce();

    view.rerender(
      currentCore!.wrap(
        <div className="h-[400px] w-[451px]">
          <TaskConversationPreview searchQuery="" task={previewTask} />
        </div>
      )
    );
    await waitFor(() =>
      expect(previewHighlightRegistry.has(TASK_PREVIEW_SEARCH_HIGHLIGHT)).toBe(false)
    );
  });

  it("uses clipped overlay highlights when the Custom Highlight API is missing", async () => {
    const response = deferred<Awaited<ReturnType<PollConversation>>>();
    const pollConversation = vi.fn<PollConversation>(() => response.promise);
    installPreviewCore(pollConversation);
    const previewTask = { ...target("fallback-highlighted"), title: "Notion title" };
    let visibleRangeRect = testRect(90, 190, 150, 220);
    let view: ReturnType<typeof render> | undefined;
    let rootRectSpy: ReturnType<typeof vi.spyOn> | undefined;

    stubProperty(window, "Highlight", {
      configurable: true,
      value: undefined,
    });
    stubProperty(CSS, "highlights", {
      configurable: true,
      value: undefined,
    });
    stubProperty(Range.prototype, "getClientRects", {
      configurable: true,
      value: () => [visibleRangeRect, testRect(0, 0, 10, 10)] as unknown as DOMRectList,
    });

    try {
      view = renderPreview(
        <div className="h-[400px] w-[451px]">
          <TaskConversationPreview searchQuery="notion" task={previewTask} />
        </div>
      );
      await waitFor(() => expect(pollConversation).toHaveBeenCalledOnce());
      const contentRoot = view.container.querySelector<HTMLElement>(
        '[data-slot="task-conversation-preview-content"]'
      )!;
      rootRectSpy = vi
        .spyOn(contentRoot, "getBoundingClientRect")
        .mockReturnValue(testRect(100, 200, 300, 400));

      await act(async () => {
        response.resolve({
          conversation: conversation("fallback-highlighted", [
            {
              ...message("fallback-answer", "assistant"),
              content: [
                {
                  text: "[Notion](https://example.com/notion), `NOTION`, notion, and Archive.",
                  type: "text",
                },
              ],
            },
          ]),
          notModified: false,
        });
        await response.promise;
      });

      const link = await waitFor(() => {
        const element = view!.container.querySelector("a");
        expect(element).not.toBeNull();
        return element!;
      });
      const code = view.container.querySelector("code")!;
      await waitFor(() =>
        expect(
          view!.container.querySelectorAll(
            `[data-slot="${TASK_PREVIEW_SEARCH_HIGHLIGHT_RECT}"]`
          )
        ).toHaveLength(3)
      );

      const overlay = view.container.querySelector(
        `[data-slot="${TASK_PREVIEW_SEARCH_HIGHLIGHT_OVERLAY}"]`
      );
      const firstRect = view.container.querySelector<HTMLElement>(
        `[data-slot="${TASK_PREVIEW_SEARCH_HIGHLIGHT_RECT}"]`
      );
      expect(overlay).toHaveAttribute("aria-hidden", "true");
      expect(firstRect).toHaveStyle({
        height: "20px",
        left: "0px",
        top: "0px",
        width: "50px",
      });
      expect(link).toHaveAttribute("href", "https://example.com/notion");
      expect(code).toHaveTextContent("NOTION");
      expect(view.container.querySelector("mark")).toBeNull();

      visibleRangeRect = testRect(250, 250, 290, 270);
      fireEvent.scroll(
        view.container.querySelector('[data-slot="scroll-area-viewport"]')!
      );
      await waitFor(() =>
        expect(
          view!.container.querySelector(
            `[data-slot="${TASK_PREVIEW_SEARCH_HIGHLIGHT_RECT}"]`
          )
        ).toHaveStyle({
          height: "20px",
          left: "150px",
          top: "50px",
          width: "40px",
        })
      );
      expect(
        view.container.querySelector(
          `[data-slot="${TASK_PREVIEW_SEARCH_HIGHLIGHT_OVERLAY}"]`
        )
      ).toBe(overlay);

      view.rerender(
        currentCore!.wrap(
          <div className="h-[400px] w-[451px]">
            <TaskConversationPreview searchQuery="archive" task={previewTask} />
          </div>
        )
      );
      await waitFor(() =>
        expect(
          view!.container.querySelectorAll(
            `[data-slot="${TASK_PREVIEW_SEARCH_HIGHLIGHT_RECT}"]`
          )
        ).toHaveLength(1)
      );
      expect(view.container.querySelector("a")).toBe(link);
      expect(view.container.querySelector("code")).toBe(code);
      expect(pollConversation).toHaveBeenCalledOnce();

      view.rerender(
        currentCore!.wrap(
          <div className="h-[400px] w-[451px]">
            <TaskConversationPreview searchQuery="" task={previewTask} />
          </div>
        )
      );
      await waitFor(() =>
        expect(
          view!.container.querySelectorAll(
            `[data-slot="${TASK_PREVIEW_SEARCH_HIGHLIGHT_RECT}"]`
          )
        ).toHaveLength(0)
      );
    } finally {
      view?.unmount();
      rootRectSpy?.mockRestore();
    }
  });

  it("shares a cache version across second and millisecond timestamps", async () => {
    const pollConversation = vi.fn<PollConversation>(async () => ({
      conversation: conversation("shared-time", [message("answer", "assistant")]),
      notModified: false,
    }));
    installPreviewCore(pollConversation);
    const view = renderPreview(
      <TaskConversationPreview
        task={{ ...target("shared-time"), updatedAt: 1_788_177_000 }}
      />
    );
    await screen.findByText("answer");
    view.rerender(
      currentCore!.wrap(
        <TaskConversationPreview
          task={{ ...target("shared-time"), updatedAt: 1_788_177_000_000 }}
        />
      )
    );
    // The same Task in seconds or milliseconds is the same version: the core reads it once.
    const versions = currentCore!.asked.map((topic) => topic.version);
    expect(new Set(versions).size).toBe(1);
    expect(pollConversation).toHaveBeenCalledTimes(1);
  });

  it("renders a cached Task without the loading skeleton", async () => {
    const pollConversation = vi.fn<PollConversation>(async () => ({
      conversation: conversation("revisited", [
        {
          ...message("revisited-message", "assistant"),
          content: [{ text: "Cached answer", type: "text" }],
        },
      ]),
      notModified: false,
    }));
    installPreviewCore(pollConversation);
    const shown = () => (
      <div className="h-[400px] w-[300px]">
        <TaskConversationPreview task={target("revisited")} />
      </div>
    );
    // Shown once, then shown again: the window still has what the core said of it.
    renderPreview(shown()).unmount();
    await waitFor(() => expect(currentCore!.asked).toHaveLength(1));
    await act(async () => {});
    renderPreview(shown());

    expect(screen.queryByTestId("task-conversation-preview-loading")).toBeNull();
    expect(await screen.findByText("Cached answer")).toBeInTheDocument();
    expect(pollConversation).toHaveBeenCalledOnce();
  });

  it("keeps the stale snapshot visible while the changed Task reloads", async () => {
    const refreshed = deferred<Awaited<ReturnType<PollConversation>>>();
    const pollConversation = vi
      .fn<PollConversation>()
      .mockResolvedValueOnce({
        conversation: conversation("running", [
          {
            ...message("old-message", "assistant"),
            content: [{ text: "Old answer", type: "text" }],
          },
        ]),
        notModified: false,
      })
      .mockReturnValueOnce(refreshed.promise);
    installPreviewCore(pollConversation);
    const view = renderPreview(
      <div className="h-[400px] w-[300px]">
        <TaskConversationPreview task={target("running")} />
      </div>
    );
    expect(await screen.findByText("Old answer")).toBeInTheDocument();

    view.rerender(
      currentCore!.wrap(
        <div className="h-[400px] w-[300px]">
          <TaskConversationPreview task={{ ...target("running"), updatedAt: 2 }} />
        </div>
      )
    );

    expect(screen.queryByTestId("task-conversation-preview-loading")).toBeNull();
    expect(screen.getByText("Old answer")).toBeInTheDocument();
    await waitFor(() => expect(pollConversation).toHaveBeenCalledTimes(2));

    await act(async () => {
      refreshed.resolve({
        conversation: conversation("running", [
          {
            ...message("new-message", "assistant"),
            content: [{ text: "New answer", type: "text" }],
          },
        ]),
        notModified: false,
      });
      await refreshed.promise;
    });
    expect(await screen.findByText("New answer")).toBeInTheDocument();
  });

  it("never lets a late response replace the newly selected task", async () => {
    const first = deferred<Awaited<ReturnType<PollConversation>>>();
    const second = deferred<Awaited<ReturnType<PollConversation>>>();
    const pollConversation = vi
      .fn<PollConversation>()
      .mockReturnValueOnce(first.promise)
      .mockReturnValueOnce(second.promise);
    installPreviewCore(pollConversation);
    const view = renderPreview(
      <div className="h-[400px] w-[300px]">
        <TaskConversationPreview task={target("first")} />
      </div>
    );
    await waitFor(() => expect(pollConversation).toHaveBeenCalledTimes(1));

    view.rerender(
      currentCore!.wrap(
        <div className="h-[400px] w-[300px]">
          <TaskConversationPreview task={target("second")} />
        </div>
      )
    );
    await waitFor(() => expect(pollConversation).toHaveBeenCalledTimes(2));

    await act(async () => {
      second.resolve({
        conversation: conversation("second", [
          {
            ...message("second-message", "assistant"),
            content: [{ text: "New selection", type: "text" }],
          },
        ]),
        notModified: false,
      });
      await second.promise;
    });
    expect(await screen.findByText("New selection")).toBeInTheDocument();

    await act(async () => {
      first.resolve({
        conversation: conversation("first", [
          {
            ...message("first-message", "assistant"),
            content: [{ text: "Stale selection", type: "text" }],
          },
        ]),
        notModified: false,
      });
      await first.promise;
    });
    expect(screen.queryByText("Stale selection")).toBeNull();
    expect(screen.getByText("New selection")).toBeInTheDocument();
  });
});

function target(conversationId: string): TaskConversationPreviewTarget {
  return {
    conversationId,
    groupId: "group-1",
    status: "completed",
    title: `Task ${conversationId}`,
    updatedAt: 1,
    workspaceId: "workspace-1",
  };
}

function conversation(id: string, messages: SalixMessage[]): CommaConversation {
  return {
    group_id: "group-1",
    id,
    kind: "agent_task",
    messages,
    status: "completed",
    title: `Task ${id}`,
  };
}

function message(id: string, role: "assistant" | "user"): SalixMessage {
  return {
    actor_type: role === "assistant" ? "agent" : "user",
    content: [{ text: id, type: "text" }],
    kind: "message",
    message_id: id,
    ...(role === "assistant"
      ? { agent_id: "agent-preview" }
      : { user_id: "user-preview" }),
  };
}

/**
 * The core as these tests see it: each `taskConversation` the preview asks for is read with `pollConversation`
 * (the server, as the core would read it), unless the core already keeps that version; the answer is the
 * projected messages. The core's own keeping (how long, how many) is its tests' (core/test/task-conversations.test.ts).
 */
function previewCore(pollConversation: PollConversation) {
  const kept = new Map<string, { version: string; value: TaskConversationValue }>();
  const asked: Record<string, unknown>[] = [];
  /** Every topic the UI subscribed to, by name. */
  const topics: string[] = [];
  const read = async (groupId: string, conversationId: string, version: string) => {
    try {
      const answer = await pollConversation(groupId, conversationId);
      const found = answer.conversation!;
      kept.set(conversationId, {
        version,
        value: {
          status: "ready",
          messages: normalizeServerMessages(found.messages ?? [], [], found.kind),
        },
      });
    } catch {
      const before = kept.get(conversationId);
      kept.set(conversationId, {
        version,
        value: { ...before?.value, status: "failed" },
      });
    }
    core.changed("taskConversation");
  };
  const core = createScriptedCore({
    owns: (name) => name === "taskConversation",
    values: (topic) => {
      if (topic.topic !== "taskConversation") return undefined;
      const known = kept.get(String(topic.conversation));
      if (!known) return { status: "loading" };
      return known.version === topic.version
        ? known.value
        : { ...known.value, status: "loading" };
    },
    onSubscribe: (topic) => {
      topics.push(String(topic.topic));
      if (topic.topic !== "taskConversation") return;
      asked.push(topic);
      const known = kept.get(String(topic.conversation));
      if (known && known.version === topic.version && known.value.status === "ready")
        return;
      void read(String(topic.group), String(topic.conversation), String(topic.version));
    },
  });
  return {
    ...core,
    asked,
    topics,
  };
}

let currentCore: ReturnType<typeof previewCore> | undefined;

type PollConversation = (
  groupId: string,
  conversationId: string
) => Promise<{ conversation?: CommaConversation; notModified: boolean }>;

/** The core whose `taskConversation` the preview reads, answered by `pollConversation` (`currentCore`). */
function installPreviewCore(pollConversation: PollConversation) {
  currentCore = previewCore(pollConversation);
}

function renderPreview(ui: ReactNode) {
  return render(currentCore!.wrap(ui));
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, reject, resolve };
}

function mockScrollport(
  viewport: HTMLElement,
  metrics: { clientHeight: number; scrollHeight: number; scrollTop: number }
) {
  Object.defineProperties(viewport, {
    clientHeight: { configurable: true, value: metrics.clientHeight },
    scrollHeight: { configurable: true, value: metrics.scrollHeight },
    scrollTop: { configurable: true, value: metrics.scrollTop, writable: true },
  });
}

function previewHighlightRanges() {
  const highlight = previewHighlightRegistry.get(TASK_PREVIEW_SEARCH_HIGHLIGHT);
  return highlight ? Array.from(highlight, (range) => range as Range) : [];
}

function testRect(left: number, top: number, right: number, bottom: number): DOMRect {
  return {
    bottom,
    height: bottom - top,
    left,
    right,
    toJSON: () => ({}),
    top,
    width: right - left,
    x: left,
    y: top,
  };
}
