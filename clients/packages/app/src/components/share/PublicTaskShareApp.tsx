import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Button, ChatPanelFile, ContentHeader, CommaLogoAnimation } from "@comma/ui";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { CommaApiClient } from "../../api";
import type { ConversationFileSource } from "../../runtime-files/fileSources";
import { ConversationThread } from "../chat/thread/ConversationThread";
import type {
  ChatAttachment,
  ChatImagePreviewRef,
  ChatMessage,
  LocalFilePreview,
} from "../chat/model/conversationChannel";
import {
  InlineTaskLinkAdapterProvider,
  passiveInlineTaskLinkAdapter,
} from "../chat/thread/inline/MessageInlineElements";
import { useTaskPanelFold, useTaskPanelOpen } from "../chat/tasks/TaskPanelFold";
import {
  PublicShareError,
  type PublicShareArtifact,
  type PublicShareClient,
  type PublicShareFailure,
  type PublicShareMessage,
  type PublicShareSummary,
} from "./publicShareApi";

type ViewState =
  | { kind: "loading" }
  | { kind: "failed"; reason: PublicShareFailure }
  | {
      kind: "ready";
      summary: PublicShareSummary;
      messages: PublicShareMessage[];
      nextAfterSeq: number | null;
    };

// Internal rows are filtered server-side, so a raw page can hold no public
// Message. Follow a few such pages before asking the reader to load more.
const EMPTY_PAGE_FOLLOW_LIMIT = 5;
// The thread addresses the conversation it renders; a public page has only the link.
const SHARE_SCOPE = "public-share";
const INLINE_IMAGE_TYPES = new Set([
  "image/png",
  "image/jpeg",
  "image/gif",
  "image/webp",
]);
const noop = () => {};

/**
 * Read-only public view of one shared Task. It reuses the app's Task layout
 * and conversation thread, and holds no Comma session.
 */
export function PublicTaskShareApp({ client }: { client: PublicShareClient }) {
  const messages = useCommaMessages();
  const [state, setState] = useState<ViewState>({ kind: "loading" });
  const [loadingMore, setLoadingMore] = useState(false);

  const readPages = useCallback(
    async (afterSeq: number, signal?: AbortSignal) => {
      const collected: PublicShareMessage[] = [];
      let next: number | null = afterSeq;
      for (
        let follow = 0;
        next !== null && follow < EMPTY_PAGE_FOLLOW_LIMIT;
        follow++
      ) {
        const page = await client.messages(next, signal);
        collected.push(...page.messages);
        next = page.next_after_seq;
        if (collected.length > 0) break;
      }
      return { messages: collected, nextAfterSeq: next };
    },
    [client]
  );

  const load = useCallback(
    (signal?: AbortSignal) => {
      setState({ kind: "loading" });
      Promise.all([client.summary(signal), readPages(0, signal)])
        .then(([summary, page]) => {
          if (signal?.aborted) return;
          setState({ kind: "ready", summary, ...page });
        })
        .catch((error: unknown) => {
          if (signal?.aborted) return;
          setState({ kind: "failed", reason: failureReason(error) });
        });
    },
    [client, readPages]
  );

  useEffect(() => {
    const controller = new AbortController();
    load(controller.signal);
    return () => controller.abort();
  }, [load]);

  useEffect(() => {
    if (state.kind === "ready") document.title = state.summary.title;
  }, [state]);

  const loadMore = async () => {
    if (state.kind !== "ready" || state.nextAfterSeq === null) return;
    setLoadingMore(true);
    try {
      const page = await readPages(state.nextAfterSeq);
      setState((current) =>
        current.kind === "ready"
          ? {
              ...current,
              messages: [...current.messages, ...page.messages],
              nextAfterSeq: page.nextAfterSeq,
            }
          : current
      );
    } catch (error) {
      setState({ kind: "failed", reason: failureReason(error) });
    } finally {
      setLoadingMore(false);
    }
  };

  return (
    <ShareFrame>
      {state.kind === "loading" ? (
        <output
          aria-busy="true"
          aria-label={messages.share_view_loading()}
          className="flex flex-1 items-center justify-center p-xl"
        >
          <span className="size-8 text-disabled">
            <CommaLogoAnimation aria-hidden="true" style={{ color: "inherit" }} />
          </span>
        </output>
      ) : state.kind === "failed" ? (
        <section
          className="flex flex-1 flex-col items-center justify-center gap-md p-xl text-center"
          data-testid="share-view-failure"
        >
          <h1 className="text-md font-semibold text-primary">
            {state.reason === "not_found"
              ? messages.share_view_not_found_title()
              : state.reason === "rate_limited"
                ? messages.share_view_rate_limited()
                : messages.share_view_unavailable()}
          </h1>
          {state.reason === "not_found" ? (
            <p className="text-sm text-tertiary">
              {messages.share_view_not_found_body()}
            </p>
          ) : (
            <Button hierarchy="secondary-gray" onPress={() => load()} size="sm">
              {messages.share_view_retry()}
            </Button>
          )}
        </section>
      ) : (
        <SharedTask
          client={client}
          loadingMore={loadingMore}
          messages={state.messages}
          nextAfterSeq={state.nextAfterSeq}
          onLoadMore={() => void loadMore()}
          summary={state.summary}
        />
      )}
    </ShareFrame>
  );
}

/** The app window: the gray canvas with one rounded content surface. */
function ShareFrame({ children }: { children: ReactNode }) {
  return (
    <div className="comma-app-shell flex h-full min-h-0 w-full min-w-0 flex-col bg-window px-xs pb-xs text-primary sm:px-md sm:pb-md">
      <header className="flex h-10 shrink-0 items-center gap-sm px-xs">
        <img alt="" className="size-5 rounded-sm" src="/brand/comma/icon.png" />
        <span className="text-sm font-medium text-secondary">Comma</span>
      </header>
      <section className="comma-content relative flex min-h-0 min-w-0 flex-1 flex-col overflow-clip bg-main-panel-bg">
        {children}
      </section>
    </div>
  );
}

function SharedTask({
  client,
  loadingMore,
  messages: sharedMessages,
  nextAfterSeq,
  onLoadMore,
  summary,
}: {
  client: PublicShareClient;
  loadingMore: boolean;
  messages: PublicShareMessage[];
  nextAfterSeq: number | null;
  onLoadMore: () => void;
  summary: PublicShareSummary;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const routeRef = useRef<HTMLElement | null>(null);
  const fold = useTaskPanelFold(routeRef, true);
  const panelOpen = useTaskPanelOpen(fold);
  const api = useMemo(() => createShareThreadApi(client), [client]);
  const linkedTask = messages.share_view_linked_task();
  const chatMessages = useMemo(
    () => sharedMessages.map((message) => toChatMessage(message, linkedTask)),
    [linkedTask, sharedMessages]
  );
  const sharedOn =
    summary.shared_at === null
      ? undefined
      : messages.share_view_shared_on({
          date: new Date(summary.shared_at * 1000).toLocaleDateString(locale, {
            dateStyle: "medium",
          }),
        });

  const download = useCallback(
    (seq: number, index: number, fileName: string) => {
      void client.attachment(seq, index).then((blob) => saveBlob(blob, fileName), noop);
    },
    [client]
  );
  const openAttachment = useCallback(
    (source: ConversationFileSource) =>
      download(Number(source.messageId), source.attachmentIndex, source.fileName ?? ""),
    [download]
  );
  const previewImage = useCallback(
    async (
      previewRef: ChatImagePreviewRef,
      signal?: AbortSignal
    ): Promise<LocalFilePreview | undefined> => {
      const address =
        typeof previewRef === "string"
          ? undefined
          : shareImageAddress(previewRef.blobRef);
      if (!address) return undefined;
      const url = URL.createObjectURL(
        await client.attachment(address.seq, address.index, signal)
      );
      return { url, release: () => URL.revokeObjectURL(url) };
    },
    [client]
  );

  const files =
    summary.artifacts.length > 0 ? (
      <SharedFiles
        artifacts={summary.artifacts}
        onDownload={download}
        truncated={summary.artifacts_truncated}
      />
    ) : null;

  return (
    <section
      aria-label={summary.title}
      className="comma-chat-route comma-share-task flex min-h-0 w-full min-w-0 flex-1 flex-col bg-main-panel-bg"
      data-variant="route"
      ref={routeRef}
    >
      <ContentHeader className="comma-chat-header">
        <div
          className="flex min-w-0 flex-1 items-center gap-sm"
          data-task-header="true"
        >
          <h1 className="comma-chat-title">{summary.title}</h1>
          {sharedOn ? (
            <span className="min-w-0 truncate text-xs text-tertiary">· {sharedOn}</span>
          ) : null}
        </div>
      </ContentHeader>
      <div
        className="comma-chat-body"
        data-panel-open={panelOpen && files ? "true" : "false"}
      >
        <div className="comma-chat-main" data-testid="share-view-thread">
          <InlineTaskLinkAdapterProvider adapter={passiveInlineTaskLinkAdapter}>
            <ConversationThread
              afterMessages={
                <>
                  {chatMessages.length === 0 && nextAfterSeq === null ? (
                    <p className="text-sm text-tertiary">
                      {messages.share_view_empty()}
                    </p>
                  ) : null}
                  {nextAfterSeq !== null ? (
                    <Button
                      hierarchy="secondary-gray"
                      isDisabled={loadingMore}
                      onPress={onLoadMore}
                      size="sm"
                    >
                      {messages.share_view_load_more()}
                    </Button>
                  ) : null}
                  {/* A folded details column moves the files below the thread. */}
                  {!panelOpen ? files : null}
                </>
              }
              api={api}
              conversationId={SHARE_SCOPE}
              conversationKind="agent_task"
              groupId={SHARE_SCOPE}
              messages={chatMessages}
              onDiscard={noop}
              onOpenAttachment={openAttachment}
              onPreviewLocalFile={previewImage}
              onRetry={noop}
              showMessageActions={false}
              workspaceId={SHARE_SCOPE}
            />
          </InlineTaskLinkAdapterProvider>
        </div>
        {files ? (
          <aside
            aria-hidden={!panelOpen}
            aria-label={messages.share_view_files()}
            className="comma-task-panel"
            data-open={panelOpen ? "true" : "false"}
          >
            <div className="comma-task-panel-inner">{panelOpen ? files : null}</div>
          </aside>
        ) : null}
      </div>
    </section>
  );
}

function SharedFiles({
  artifacts,
  onDownload,
  truncated,
}: {
  artifacts: PublicShareArtifact[];
  onDownload: (seq: number, index: number, fileName: string) => void;
  truncated: boolean;
}) {
  const messages = useCommaMessages();
  return (
    <section className="comma-task-panel-section" data-testid="share-view-files">
      <h2 className="comma-task-panel-heading">{messages.share_view_files()}</h2>
      <div className="flex flex-col gap-sm">
        {artifacts.map((artifact) => (
          <ChatPanelFile
            fileName={artifact.file_name}
            fileSize={artifact.size}
            key={`${artifact.seq}:${artifact.index}`}
            mimeType={artifact.mime_type}
            onPreview={() =>
              onDownload(artifact.seq, artifact.index, artifact.file_name)
            }
            testId="share-view-artifact"
          />
        ))}
      </div>
      {truncated ? (
        <p className="text-xs text-tertiary">{messages.share_view_files_truncated()}</p>
      ) : null}
    </section>
  );
}

/** Maps the public projection to the thread's presentation model. */
function toChatMessage(message: PublicShareMessage, linkedTask: string): ChatMessage {
  const assistant = message.role === "assistant";
  const parts: NonNullable<ChatMessage["parts"]> = [];
  const attachments: ChatAttachment[] = [];
  for (const block of message.content) {
    if (block.type === "text") {
      parts.push({ kind: "markdown", text: block.text });
    } else if (block.type === "task_ref") {
      parts.push({ kind: "markdown", text: `_${linkedTask}_` });
    } else {
      const image = INLINE_IMAGE_TYPES.has(block.mime_type);
      attachments.push({
        attachmentIndex: block.index,
        blockType: block.type,
        fileName: block.file_name,
        mimeType: block.mime_type,
        size: block.size,
        ...(assistant && image
          ? {
              agentId: SHARE_SCOPE,
              blobRef: shareImageRef(message.seq, block.index, block.size),
            }
          : {}),
      });
    }
  }
  return {
    ...(assistant ? { actorId: SHARE_SCOPE } : {}),
    attachments,
    ...(message.created_at === undefined ? {} : { createdAt: message.created_at }),
    delivery: "sent",
    messageId: String(message.seq),
    parts,
    refs: [],
    role: assistant ? "assistant" : "user",
    source: "server",
    status: "committed",
    text: parts.map((part) => (part.kind === "markdown" ? part.text : "")).join("\n\n"),
  };
}

/**
 * The thread previews Agent images by blob ref. A public page has no blob
 * identity, so it mints a local stand-in that encodes the Message sequence and
 * block index. It never leaves this page: `previewImage` decodes it and reads
 * the public attachment route.
 */
function shareImageRef(seq: number, index: number, size: number) {
  return {
    hash: "0".repeat(64),
    kind: "blob" as const,
    size,
    uuid: seq.toString(16).padStart(24, "0") + index.toString(16).padStart(8, "0"),
  };
}

function shareImageAddress(ref: { uuid: string; hash: string }) {
  if (ref.hash !== "0".repeat(64) || !/^[0-9a-f]{32}$/.test(ref.uuid)) return undefined;
  return {
    seq: Number.parseInt(ref.uuid.slice(0, 24), 16),
    index: Number.parseInt(ref.uuid.slice(24), 16),
  };
}

/**
 * The thread reads file bytes only through `fetchConversationAttachment`,
 * addressed by the Message ID it was given (the public sequence). Every other
 * client operation is unavailable to a public reader and rejects.
 */
function createShareThreadApi(client: PublicShareClient): CommaApiClient {
  const implemented: Partial<CommaApiClient> = {
    fetchConversationAttachment: (
      _groupId,
      _conversationId,
      messageId,
      index,
      options
    ) => client.attachment(Number(messageId), index, options?.signal),
    getMessageContext: async () => [],
  };
  return new Proxy(implemented, {
    get(target, property) {
      if (property in target) return target[property as keyof CommaApiClient];
      // Not a thenable, and no other member exists.
      if (typeof property !== "string" || property === "then") return undefined;
      return () => Promise.reject(new PublicShareError("unavailable"));
    },
  }) as CommaApiClient;
}

function failureReason(error: unknown): PublicShareFailure {
  return error instanceof PublicShareError ? error.reason : "unavailable";
}

function saveBlob(blob: Blob, fileName: string) {
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = fileName;
  anchor.rel = "noopener";
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30_000);
}
