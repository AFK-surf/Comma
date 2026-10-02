import { TaskDetailsPanel } from "../../tasks/TaskDetailsPanel";
import {
  act,
  fireEvent,
  render,
  screen,
  waitFor,
  within,
} from "@comma/test-utils/render";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CommaApiClient } from "../../../../api";
import { ConversationThread } from "../ConversationThread";
import type { ChatMessage, LocalFilePreview } from "../../model/conversationChannel";
import { composeMessageWithQuotes } from "../../model/protocol";

// Keep MarkdownStream, the trusted inline compiler, and every attachment
// component real. Only the image byte/lease boundary is supplied by the test.
const previewUrl =
  "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==";
const attachments: ChatMessage["attachments"] = [
  {
    blockType: "image",
    fileName: "diagram.png",
    localFileRef: `lfi1_${"a".repeat(43)}`,
    mimeType: "image/png",
    size: 67,
  },
  {
    blockType: "file",
    fileName: "report.pdf",
    mimeType: "application/pdf",
    size: 2048,
    attachmentIndex: 1,
  },
  {
    blockType: "file",
    fileName: "recording.mp3",
    mimeType: "audio/mpeg",
    size: 4096,
    attachmentIndex: 2,
  },
  {
    blockType: "file",
    fileName: "walkthrough.mp4",
    mimeType: "video/mp4",
    size: 8192,
    attachmentIndex: 3,
  },
];

function message(
  messageId: string,
  role: string,
  text: string,
  extra: Partial<ChatMessage> = {}
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
    ...extra,
  };
}
const noop = () => {};
const fileCard = (position: number) =>
  screen.queryByTestId(`chat-attachment-file-msg_agent_media-${position}`);

describe("real chat Markdown and attachment composition", () => {
  it("keeps a streamed Comma reply in its source turn when an external user message arrives", async () => {
    const home = message("msg_home", "user", "Home question");
    const external = message("msg_wechat", "user", "WeChat question", {
      platformSource: "wechat",
    });
    const draft = {
      conversationId: "cnv_1",
      draftId: "draft_home",
      responseKey: "response_home",
      sourceMessageIds: [home.messageId],
      status: "streaming" as const,
      text: "Working on the Home question",
    };
    const common = {
      groupId: "grp_1",
      workspaceId: "wsp_1",
      onDiscard: noop,
      onRetry: noop,
    };
    const { container, rerender } = render(
      <ConversationThread {...common} messages={[home]} assistantDraft={draft} />
    );
    const draftNode = await screen.findByTestId("chat-assistant-draft");
    rerender(
      <ConversationThread
        {...common}
        messages={[home, external]}
        assistantDraft={draft}
      />
    );
    expect(screen.getByTestId("chat-assistant-draft")).toBe(draftNode);
    expect(draftNode.closest("[data-turn-key]")).toBe(
      container
        .querySelector('[data-message-id="msg_home"]')
        ?.closest("[data-turn-key]")
    );
    expect(draftNode.closest("[data-turn-key]")).not.toContainElement(
      screen.getByText("WeChat question")
    );
  });

  it("hands the streamed Comma row to its own reply when a platform reply shares the snapshot", async () => {
    const home = message("msg_home", "user", "Home question");
    const draft = {
      conversationId: "cnv_1",
      draftId: "draft_home",
      responseKey: "response_home",
      sourceMessageIds: [home.messageId],
      status: "completed" as const,
      text: "Home answer",
    };
    const common = {
      groupId: "grp_1",
      workspaceId: "wsp_1",
      onDiscard: noop,
      onRetry: noop,
    };
    const { container, rerender } = render(
      <ConversationThread {...common} messages={[home]} assistantDraft={draft} />
    );
    const draftNode = await screen.findByTestId("chat-assistant-draft");
    rerender(
      <ConversationThread
        {...common}
        messages={[
          home,
          message("msg_home_reply", "assistant", "Home answer"),
          message("msg_telegram_reply", "assistant", "Telegram answer", {
            platformSource: "telegram",
          }),
        ]}
      />
    );
    expect(container.querySelector('[data-message-id="msg_home_reply"]')).toBe(
      draftNode
    );
    expect(container.querySelector('[data-message-id="msg_telegram_reply"]')).not.toBe(
      draftNode
    );
    expect(draftNode.querySelector("[data-platform]")).toBeNull();
  });

  it("renders external source text literally instead of interpreting Comma composer metadata", () => {
    const text = [
      "Quoted from this conversation:",
      "> Literal quote text",
      "",
      "[A task](comma:task/cnv_literal)",
      "",
      "Attached files in your workspace:",
      "- report.txt (workspace file: /report.txt)",
      "",
      "<user-reminder>",
      '<browser-element-inspection id="literal" />',
      "<browser_element_context>literal context</browser_element_context>",
      "</user-reminder>",
    ].join("\n");
    const command = "<salix-command>stop</salix-command>";
    const { container } = render(
      <ConversationThread
        groupId="grp_1"
        workspaceId="wsp_1"
        messages={[
          message("msg_literal", "user", text, { platformSource: "wechat" }),
          message("msg_command", "user", command, { platformSource: "telegram" }),
        ]}
        onDiscard={noop}
        onRetry={noop}
      />
    );
    expect(
      container.querySelector(
        '[data-message-id="msg_literal"] .comma-chat-user-bubble-content'
      )?.textContent
    ).toBe(text);
    expect(
      container.querySelector(
        '[data-message-id="msg_command"] .comma-chat-user-bubble-content'
      )?.textContent
    ).toBe(command);
    expect(screen.queryByTestId("chat-message-quote")).toBeNull();
    expect(container.querySelector('[data-testid^="chat-inline-task"]')).toBeNull();
  });

  it("identifies external user messages beside the copy action while keeping agent replies visible", async () => {
    const { container } = render(
      <ConversationThread
        defaultAssistantActorRole="router"
        groupId="grp_1"
        workspaceId="wsp_1"
        messages={[
          message("msg_wechat_user", "user", "WeChat question", {
            platformSource: "wechat",
          }),
          message("msg_wechat_reply", "assistant", "WeChat answer", {
            actorRole: "router",
            platformSource: "wechat",
            threadRootMessageId: "msg_wechat_user",
          }),
          message("msg_telegram_reply", "assistant", "Telegram answer", {
            actorRole: "router",
            platformSource: "telegram",
            threadRootMessageId: "msg_wechat_user",
          }),
          message("msg_home_user", "user", "Home question"),
          message("msg_home_reply", "assistant", "Home answer"),
        ]}
        onDiscard={noop}
        onRetry={noop}
      />
    );

    await screen.findByText("WeChat answer");
    await screen.findByText("Telegram answer");
    const article = container.querySelector('[data-message-id="msg_wechat_user"]')!;
    const actions = within(article as HTMLElement).getByTestId(
      "chat-message-actions-msg_wechat_user"
    );
    expect(within(actions).getByText("WeChat", { exact: true })).toBeInTheDocument();
    expect(
      within(actions).getByRole("button", { name: "Copy message" })
    ).toBeInTheDocument();
    for (const id of [
      "msg_wechat_reply",
      "msg_telegram_reply",
      "msg_home_user",
      "msg_home_reply",
    ]) {
      expect(
        container.querySelector(`[data-message-id="${id}"] [data-platform]`)
      ).toBeNull();
    }
    expect(
      container.querySelector('[data-message-id="msg_wechat_reply"]')
    ).toHaveAttribute("data-message-group-last", "true");
    expect(
      container.querySelector('[data-message-id="msg_telegram_reply"]')
    ).toHaveAttribute("data-message-group-first", "true");
  });

  it("uses the same Worker colors in messages and Task details", async () => {
    vi.stubGlobal("crypto", process.getBuiltinModule("crypto").webcrypto);
    const agentId = "agt1_worker_1";
    const actorId = "actor_zJrB7_pSoHdVDU_PGYQtCsyypRFaRjMV2wIrMYjkSG8";
    const workerMessage = message("msg_worker", "assistant", "Done", {
      actorId: agentId,
      actorRole: "worker",
    });
    try {
      const { container } = render(
        <>
          <ConversationThread
            groupId="grp_1"
            workspaceId="wsp_1"
            messages={[workerMessage]}
            onDiscard={noop}
            onRetry={noop}
          />
          <TaskDetailsPanel
            conversation={{
              group_id: "grp_1",
              id: "cnv_1",
              title: "Task",
              status: "running",
              kind: "agent_task",
            }}
            canDone={false}
            doneState="idle"
            groupId="grp_1"
            onDone={noop}
            open
            worker={{ participantId: "p_worker", actorId, name: "Worker" }}
          />
        </>
      );
      const sidebarAvatar = container.querySelector<HTMLElement>(
        '[data-testid="task-panel-worker"] .comma-session-avatar'
      );
      expect(sidebarAvatar).not.toBeNull();
      await waitFor(() => {
        const messageAvatar = container.querySelector<HTMLElement>(
          ".comma-chat-message-assistant > .comma-chat-assistant-source-avatar"
        );
        expect(messageAvatar?.style.backgroundImage).toBe(
          sidebarAvatar?.style.backgroundImage
        );
        expect(messageAvatar?.style.backgroundColor).toBe(
          sidebarAvatar?.style.backgroundColor
        );
      });
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("hands a growing Markdown reply to its canonical trusted task, image group, and media file cards", async () => {
    const release = vi.fn();
    const preview = vi.fn(async () => ({ url: previewUrl, release }));
    const prompt = message(
      "msg_multimodal_prompt",
      "user",
      "Show the report and its files"
    );
    const draft = {
      conversationId: "cnv_multimodal",
      draftId: "draft_multimodal",
      responseKey: "response_multimodal",
      sourceMessageIds: [prompt.messageId],
      status: "streaming" as const,
      text: "## Report\n\nReady",
    };
    const common = {
      groupId: "grp_1",
      workspaceId: "wsp_1",
      onDiscard: noop,
      onRetry: noop,
      onPreviewLocalFile: preview,
    };
    const { container, rerender, unmount } = render(
      <ConversationThread {...common} messages={[prompt]} assistantDraft={draft} />
    );
    const article = await screen.findByTestId("chat-assistant-draft");
    const heading = screen.getByRole("heading", { name: "Report" });
    rerender(
      <ConversationThread
        {...common}
        messages={[prompt]}
        assistantDraft={{ ...draft, text: "## Report\n\nReady **now**.\n\nTask: " }}
      />
    );
    await waitFor(() =>
      expect(article.querySelector("strong")).toHaveTextContent("now")
    );
    expect(screen.getByRole("heading", { name: "Report" })).toBe(heading);
    expect(article.querySelector(".comma-chat-block-extras")).toBeNull();

    const canonical = message(
      "msg_multimodal_answer",
      "assistant",
      "## Report\n\nReady **now**.\n\nTask: Review report.",
      {
        attachments,
        parts: [
          { kind: "markdown", text: "## Report\n\nReady **now**.\n\nTask: " },
          {
            kind: "inline-task",
            task: {
              conversationId: "cnv_report_review",
              title: "Review report",
              status: "completed",
              unavailable: false,
            },
          },
          { kind: "markdown", text: "." },
        ],
      }
    );
    rerender(<ConversationThread {...common} messages={[prompt, canonical]} />);
    expect(container.querySelector('[data-message-id="msg_multimodal_answer"]')).toBe(
      article
    );
    expect(screen.getByRole("heading", { name: "Report" })).toBe(heading);
    expect(screen.getByTestId("chat-inline-task-cnv_report_review")).toHaveTextContent(
      "Review report"
    );
    const image = await screen.findByRole("img", { name: "diagram.png" });
    await waitFor(() => expect(image).toHaveAttribute("src", previewUrl));
    // An agent's image keeps its own ratio instead of a cropped group card.
    expect(article.querySelectorAll(".comma-chat-inline-image")).toHaveLength(1);
    expect(article.querySelectorAll(".chat-panel-image-group-card")).toHaveLength(0);
    for (const [index, name] of [
      "report.pdf",
      "recording.mp3",
      "walkthrough.mp4",
    ].entries()) {
      expect(
        screen.getByTestId(`chat-attachment-file-msg_multimodal_answer-${index + 1}`)
      ).toHaveTextContent(name);
    }
    // This thread has no attachment byte source, so nothing can play in place:
    // audio and video stay downloadable file metadata.
    expect(article.querySelector("audio, video")).toBeNull();
    expect(article.querySelector("comma-inline")).toBeNull();
    expect(article.textContent).not.toContain("data-key=");
    expect(preview).toHaveBeenCalledOnce();

    // Equal refreshed objects must not reacquire image bytes or remount media.
    rerender(
      <ConversationThread {...common} messages={[prompt, structuredClone(canonical)]} />
    );
    expect(screen.getByRole("img", { name: "diagram.png" })).toBe(image);
    expect(preview).toHaveBeenCalledOnce();
    unmount();
    await act(async () => Promise.resolve());
    expect(release).toHaveBeenCalledOnce();
  });

  it("keeps user images separate from file pills, including audio and video files", async () => {
    const preview = vi.fn(async () => ({ url: previewUrl, release: vi.fn() }));
    const { container } = render(
      <ConversationThread
        messages={[
          message("msg_user_media", "user", "Please review **these** files", {
            attachments,
          }),
        ]}
        groupId="grp_1"
        workspaceId="wsp_1"
        onDiscard={noop}
        onRetry={noop}
        onPreviewLocalFile={preview}
      />
    );
    await screen.findByRole("img", { name: "diagram.png" });
    expect(container.querySelectorAll(".chat-panel-image-group-card")).toHaveLength(1);
    for (const [index, name] of [
      "report.pdf",
      "recording.mp3",
      "walkthrough.mp4",
    ].entries()) {
      expect(
        screen.getByTestId(`chat-attachment-pill-msg_user_media-${index + 1}`)
      ).toHaveTextContent(name);
    }
    expect(container.querySelector(".comma-chat-user-bubble")).toHaveTextContent(
      "Please review **these** files"
    );
    expect(container.querySelector("audio, video")).toBeNull();
  });

  describe("agent inline media", () => {
    const blobRef = {
      hash: "a".repeat(64),
      kind: "blob" as const,
      size: 67,
      uuid: "b".repeat(32),
    };
    const agentMedia: ChatMessage["attachments"] = [
      {
        agentId: "agt_1",
        attachmentIndex: 0,
        blobRef,
        blockType: "file",
        fileName: "chart.png",
        mimeType: "image/png",
        size: 67,
      },
      {
        attachmentIndex: 1,
        blockType: "file",
        fileName: "demo.webm",
        mimeType: "video/webm",
        size: 8192,
      },
      {
        attachmentIndex: 2,
        blockType: "file",
        fileName: "bundle.zip",
        mimeType: "application/zip",
        size: 2048,
      },
    ];
    const renderAgentMedia = (
      read: CommaApiClient["fetchConversationAttachment"],
      preview = vi.fn(
        async (): Promise<LocalFilePreview | undefined> => ({
          url: previewUrl,
          release: vi.fn(),
        })
      )
    ) => {
      vi.spyOn(URL, "createObjectURL").mockReturnValue("blob:inline-video");
      vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined);
      const api = { fetchConversationAttachment: read } as unknown as CommaApiClient;
      const thread = (threadAttachments: ChatMessage["attachments"]) => (
        <ConversationThread
          api={api}
          conversationId="cnv_media"
          groupId="grp_1"
          messages={[
            message("msg_agent_media", "assistant", "Here is the run output.", {
              attachments: threadAttachments,
            }),
          ]}
          onDiscard={noop}
          onPreviewLocalFile={preview}
          onRetry={noop}
          workspaceId="wsp_1"
        />
      );
      return { ...render(thread(agentMedia)), preview, thread };
    };
    afterEach(() => vi.restoreAllMocks());

    it("shows an agent's image and video files in the message and keeps other files as cards", async () => {
      const read = vi.fn(async () => new Blob(["webm-bytes"]));
      const { container, preview, rerender, thread } = renderAgentMedia(read);

      const image = await screen.findByRole("img", { name: "chart.png" });
      expect(image).toHaveAttribute("src", previewUrl);
      expect(container.querySelectorAll(".comma-chat-inline-image")).toHaveLength(1);
      expect(container.querySelectorAll(".chat-panel-image-group-card")).toHaveLength(
        0
      );
      expect(preview).toHaveBeenCalledWith(
        expect.objectContaining({
          blobRef,
          kind: "agent-blob",
          mediaType: "image/png",
        }),
        expect.anything()
      );

      const video = await waitFor(() => {
        const element = container.querySelector("video");
        expect(element).not.toBeNull();
        return element!;
      });
      expect(video).toHaveAttribute("src", "blob:inline-video");
      expect(video).toHaveAttribute("preload", "metadata");
      expect(video).toHaveAccessibleName("demo.webm");
      expect(video.closest(".comma-chat-inline-video")).not.toBeNull();
      expect(read).toHaveBeenCalledWith(
        "grp_1",
        "cnv_media",
        "msg_agent_media",
        1,
        expect.anything()
      );
      // The decoder gets the allowlisted type, whatever the endpoint answered.
      expect(vi.mocked(URL.createObjectURL).mock.calls[0]![0]).toHaveProperty(
        "type",
        "video/webm"
      );

      expect(fileCard(0)).toBeNull();
      expect(fileCard(1)).toBeNull();
      expect(fileCard(2)).toHaveTextContent("bundle.zip");

      // An equal refreshed transcript must not refetch the bytes or restart playback.
      rerender(thread(structuredClone(agentMedia)));
      expect(container.querySelector("video")).toBe(video);
      expect(read).toHaveBeenCalledOnce();
    });

    it("falls back to the file card when the video bytes cannot be read", async () => {
      const { container } = renderAgentMedia(
        vi.fn(async () => Promise.reject(new Error("gone")))
      );
      await waitFor(() => expect(fileCard(1)).toHaveTextContent("demo.webm"));
      expect(container.querySelector("video")).toBeNull();
      expect(
        screen.queryByTestId("chat-attachment-video-msg_agent_media-1")
      ).toBeNull();
    });

    it("falls back to the file card when the renderer cannot decode the video", async () => {
      const { container } = renderAgentMedia(
        vi.fn(async () => new Blob(["not-a-video"]))
      );
      const video = await waitFor(() => {
        const element = container.querySelector("video");
        expect(element).not.toBeNull();
        return element!;
      });
      fireEvent.error(video);
      await waitFor(() => expect(fileCard(1)).toHaveTextContent("demo.webm"));
      expect(container.querySelector("video")).toBeNull();
    });

    it("falls back to the file card when the image preview is unavailable", async () => {
      renderAgentMedia(
        vi.fn(async () => new Blob(["webm-bytes"])),
        vi.fn(async () => undefined)
      );
      await waitFor(() => expect(fileCard(0)).toHaveTextContent("chart.png"));
      expect(screen.queryByRole("img", { name: "chart.png" })).toBeNull();
    });
  });
});

const streamingDraft = (text: string) => ({
  conversationId: "cnv_stream",
  draftId: "draft_stream",
  responseKey: "response_stream",
  sourceMessageIds: ["msg_prompt"],
  status: "streaming" as const,
  text,
});

/**
 * React stores each host element's latest props on the node itself. A row
 * that renders again hands its elements a new props object, so a changed
 * object is one render of that element; an unchanged one is a skipped row.
 */
function renderedProps(element: Element) {
  const key = Object.keys(element).find((name) => name.startsWith("__reactProps$"));
  if (!key) throw new Error("Element was not rendered by React");
  return (element as unknown as Record<string, unknown>)[key];
}

describe("a streaming reply beside mounted history", () => {
  // Two reply chains interleave, so the later chain-A reply shows a preview of
  // its root. A user turn carries a quote and a file to mount every row part.
  const history = [
    message("msg_chain_a", "user", "Plan the launch", { createdAt: 1_000 }),
    message("msg_chain_a_reply", "assistant", "Launch plan ready", {
      actorId: "agt1_worker_a",
      actorRole: "worker",
      replyToMessageId: "msg_chain_a",
      threadRootMessageId: "msg_chain_a",
    }),
    message(
      "msg_chain_b",
      "user",
      composeMessageWithQuotes("Check the budget", ["Launch plan ready"]),
      { attachments: [attachments[1]!], createdAt: 200_000 }
    ),
    message("msg_chain_b_reply", "assistant", "Budget checked", {
      actorId: "agt1_worker_b",
      actorRole: "worker",
      replyToMessageId: "msg_chain_b",
      threadRootMessageId: "msg_chain_b",
    }),
    message("msg_chain_a_followup", "assistant", "Launch plan updated", {
      actorId: "agt1_worker_a",
      actorRole: "worker",
      replyToMessageId: "msg_chain_a_reply",
      threadRootMessageId: "msg_chain_a",
    }),
    message("msg_prompt", "user", "Summarize everything", { createdAt: 400_000 }),
  ];
  const common = {
    groupId: "grp_1",
    workspaceId: "wsp_1",
    onDiscard: noop,
    onRetry: noop,
  };
  const historyIds = history.map((item) => item.messageId);

  function historyRowElements(container: HTMLElement) {
    const elements = new Map<string, Element>();
    for (const messageId of historyIds) {
      const row = container.querySelector(`[data-message-id="${messageId}"]`);
      if (!row) throw new Error(`History row ${messageId} is not mounted`);
      elements.set(messageId, row);
      row
        .querySelectorAll(
          "[data-reply-preview-target], .comma-chat-user-bubble, .comma-chat-message-quote, .comma-chat-block-extras"
        )
        .forEach((part, index) => elements.set(`${messageId}:part:${index}`, part));
    }
    return elements;
  }
  function snapshotRenders(container: HTMLElement) {
    return new Map(
      [...historyRowElements(container)].map(([name, element]) => [
        name,
        renderedProps(element),
      ])
    );
  }
  function rerenderedNames(container: HTMLElement, before: Map<string, unknown>) {
    return [...historyRowElements(container)]
      .filter(([name, element]) => before.get(name) !== renderedProps(element))
      .map(([name]) => name);
  }

  it("renders only the streaming row from the draft's start to its commit", async () => {
    const { container, rerender } = render(
      <ConversationThread {...common} messages={history} />
    );
    // The fixture has to mount the parts this test protects.
    expect(
      container.querySelector('[data-reply-preview-target="msg_chain_a"]')
    ).not.toBeNull();
    expect(screen.getByTestId("chat-message-quote")).toBeInTheDocument();
    expect(container.querySelector(".comma-chat-block-extras")).not.toBeNull();
    // User bubbles measure themselves in the frame after they mount.
    await act(
      () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()))
    );
    const before = snapshotRenders(container);

    // A live reply starts empty, gains its first text, and then grows.
    rerender(
      <ConversationThread
        {...common}
        messages={history}
        assistantDraft={streamingDraft("")}
      />
    );
    rerender(
      <ConversationThread
        {...common}
        messages={history}
        assistantDraft={streamingDraft("First")}
      />
    );
    const streaming = await screen.findByTestId("chat-assistant-draft");
    let streamingRender = renderedProps(streaming);
    for (const text of ["First words", "First words of", "First words of the reply"]) {
      rerender(
        <ConversationThread
          {...common}
          messages={history}
          assistantDraft={streamingDraft(text)}
        />
      );
      await waitFor(() => expect(streaming).toHaveTextContent(text));
      expect(renderedProps(streaming)).not.toBe(streamingRender);
      streamingRender = renderedProps(streaming);
    }
    // The canonical reply replaces the draft in the same row.
    rerender(
      <ConversationThread
        {...common}
        messages={[
          ...history,
          message("msg_answer", "assistant", "First words of the reply", {
            actorId: "agt1_worker_a",
            actorRole: "worker",
            replyToMessageId: "msg_prompt",
            threadRootMessageId: "msg_prompt",
          }),
        ]}
      />
    );
    expect(container.querySelector('[data-message-id="msg_answer"]')).toBe(streaming);

    expect(rerenderedNames(container, before)).toEqual([]);
  });

  // Streaming re-creates the thread's reveal and window callbacks. A reply
  // preview that skipped those renders must still act on the current thread.
  async function streamPastHistory(
    rerender: (ui: React.ReactElement) => void,
    streaming: string
  ) {
    for (const text of ["", "First", streaming]) {
      rerender(
        <ConversationThread
          {...common}
          messages={history}
          assistantDraft={streamingDraft(text)}
        />
      );
    }
    await waitFor(() =>
      expect(screen.getByTestId("chat-assistant-draft")).toHaveTextContent(streaming)
    );
  }

  it("jumps to a history reply target while a reply streams", async () => {
    // The thread mounts before its transcript loads, so a reveal handler kept
    // from the first render would not find the target's turn.
    const { container, rerender } = render(
      <ConversationThread {...common} messages={[]} />
    );
    await streamPastHistory(rerender, "First words");

    fireEvent.click(
      container.querySelector<HTMLElement>('[data-reply-preview-target="msg_chain_a"]')!
    );

    const target = container.querySelector('[data-message-id="msg_chain_a"]');
    await waitFor(() => expect(target).toHaveFocus());
    // The clicked chain stays highlighted until the jump arrives.
    expect(target).toHaveAttribute("data-reply-chain-state", "active");
    expect(container.querySelector('[data-message-id="msg_chain_b"]')).toHaveAttribute(
      "data-reply-chain-state",
      "muted"
    );
  });

  it("highlights a hovered reply chain across draft revisions", async () => {
    vi.stubGlobal("matchMedia", (query: string) => ({
      matches: query === "(hover: hover) and (pointer: fine)",
      media: query,
      addEventListener: noop,
      removeEventListener: noop,
    }));
    try {
      const { container, rerender } = render(
        <ConversationThread {...common} messages={history} />
      );
      await streamPastHistory(rerender, "First words");
      const chainStates = () =>
        Object.fromEntries(
          historyIds.map((messageId) => [
            messageId,
            container
              .querySelector(`[data-message-id="${messageId}"]`)
              ?.getAttribute("data-reply-chain-state"),
          ])
        );
      const preview = container.querySelector<HTMLElement>(
        '[data-reply-preview-target="msg_chain_a"]'
      )!;

      fireEvent.pointerEnter(preview, { pointerType: "mouse" });
      const hovered = {
        msg_chain_a: "active",
        msg_chain_a_reply: "active",
        msg_chain_b: "muted",
        msg_chain_b_reply: "muted",
        msg_chain_a_followup: "active",
        msg_prompt: "muted",
      };
      expect(chainStates()).toEqual(hovered);

      rerender(
        <ConversationThread
          {...common}
          messages={history}
          assistantDraft={streamingDraft("First words of the reply")}
        />
      );
      expect(chainStates()).toEqual(hovered);

      fireEvent.pointerLeave(preview, { pointerType: "mouse" });
      expect(container.querySelector("[data-reply-chain-state]")).toBeNull();
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
