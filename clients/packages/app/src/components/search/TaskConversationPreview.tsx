import { useCommaMessages } from "@comma/i18n/react";
import { Button, cx, spacing } from "@comma/ui";
import { useEffect, useId, useRef, useState } from "react";
import type { CommaApiClient } from "../../api";
import { ConversationThread } from "../chat/thread/ConversationThread";
import {
  InlineTaskLinkAdapterProvider,
  passiveInlineTaskLinkAdapter,
} from "../chat/thread/inline/MessageInlineElements";
import {
  loadTaskConversationPreview,
  type TaskConversationPreviewData,
  type TaskConversationPreviewTarget,
} from "./taskConversationPreviewLoader";
import {
  TASK_PREVIEW_SEARCH_HIGHLIGHT_OVERLAY,
  usePreviewSearchHighlight,
} from "./previewSearchHighlight";

type PreviewState =
  | { key: string; status: "error" }
  | { key: string; status: "loading" }
  | { data: TaskConversationPreviewData; key: string; status: "ready" };

export type TaskConversationPreviewProps = {
  apiClient: CommaApiClient;
  className?: string;
  /** Use a bounded tail for small embedded views. The search preview keeps its full snapshot. */
  messageLimit?: number;
  searchQuery?: string;
  /** False when the host already names the Task, as the share dialog's title does. */
  showTitle?: boolean;
  task: TaskConversationPreviewTarget;
};

const COMMAND_PREVIEW_EDGE_MASK = { size: spacing["4xl"] } as const;

/** A compact, read-only view of the selected task's canonical conversation snapshot. */
export function TaskConversationPreview({
  apiClient,
  className,
  messageLimit,
  searchQuery = "",
  showTitle = true,
  task,
}: TaskConversationPreviewProps) {
  const messages = useCommaMessages();
  const titleId = useId();
  const contentRef = useRef<HTMLDivElement>(null);
  const highlightOverlayRef = useRef<HTMLDivElement>(null);
  const generation = useRef(0);
  const [retry, setRetry] = useState(0);
  const { conversationId, groupId, status, title, updatedAt, workspaceId } = task;
  const requestKey = `${workspaceId}\u0000${groupId}\u0000${conversationId}\u0000${updatedAt ?? ""}\u0000${status ?? ""}\u0000${messageLimit ?? "all"}\u0000${retry}`;
  const [state, setState] = useState<PreviewState>({
    key: requestKey,
    status: "loading",
  });
  const visibleState: PreviewState =
    state.key === requestKey ? state : { key: requestKey, status: "loading" };
  usePreviewSearchHighlight(contentRef, highlightOverlayRef, searchQuery);

  useEffect(() => {
    const controller = new AbortController();
    const signal =
      messageLimit === undefined
        ? controller.signal
        : AbortSignal.any([controller.signal, AbortSignal.timeout(10_000)]);
    const currentGeneration = ++generation.current;
    setState({ key: requestKey, status: "loading" });

    const target: TaskConversationPreviewTarget = {
      conversationId,
      groupId,
      title,
      workspaceId,
      ...(status === undefined ? {} : { status }),
      ...(updatedAt === undefined ? {} : { updatedAt }),
    };
    void loadTaskConversationPreview(apiClient, target, signal, messageLimit).then(
      (data) => {
        if (generation.current === currentGeneration && !signal.aborted) {
          setState({ data, key: requestKey, status: "ready" });
        }
      },
      (error: unknown) => {
        if (
          generation.current === currentGeneration &&
          !controller.signal.aborted &&
          (signal.reason?.name === "TimeoutError" || !isAbortError(error))
        ) {
          setState({ key: requestKey, status: "error" });
        }
      }
    );

    return () => {
      generation.current += 1;
      controller.abort();
    };
  }, [
    apiClient,
    conversationId,
    groupId,
    messageLimit,
    requestKey,
    status,
    title,
    updatedAt,
    workspaceId,
  ]);

  return (
    <section
      {...(showTitle ? { "aria-labelledby": titleId } : { "aria-label": title })}
      className={cx(
        "flex size-full min-h-0 flex-col overflow-hidden rounded-2xl border-[length:var(--border-width-0-5)] border-primary bg-popup-secondary shadow-lg",
        className
      )}
      data-slot="task-conversation-preview"
    >
      {showTitle ? (
        <header className="flex h-10 shrink-0 items-center border-b-[length:var(--border-width-0-5)] border-primary px-lg">
          <h2
            className="min-w-0 truncate text-xs font-medium text-secondary"
            id={titleId}
            title={title}
          >
            {title}
          </h2>
        </header>
      ) : null}
      <div
        ref={contentRef}
        className="relative min-h-0 flex-1 overflow-hidden"
        data-slot="task-conversation-preview-content"
      >
        {visibleState.status === "loading" ? (
          <TaskConversationPreviewSkeleton label={messages.common_loading()} />
        ) : visibleState.status === "error" ? (
          <div
            className="flex size-full items-center justify-center px-lg"
            data-testid="task-conversation-preview-error"
            role="alert"
          >
            <Button
              hierarchy="tertiary-gray"
              onPress={() => setRetry((value) => value + 1)}
              size="sm"
            >
              {messages.common_retry()}
            </Button>
          </div>
        ) : visibleState.data.messages.length === 0 ? (
          <p className="flex size-full items-center justify-center px-lg text-center text-sm text-tertiary">
            {messages.task_no_messages()}
          </p>
        ) : (
          <div
            className="comma-chat-route flex size-full min-h-0 min-w-0 flex-col bg-popup-secondary"
            data-slot="task-conversation-preview-thread"
            data-variant="command-preview"
          >
            <InlineTaskLinkAdapterProvider adapter={passiveInlineTaskLinkAdapter}>
              <ConversationThread
                api={apiClient}
                conversationId={conversationId}
                contentMode="display-only"
                groupId={groupId}
                messages={visibleState.data.messages}
                onDiscard={ignoreMessageAction}
                onRetry={ignoreMessageAction}
                scrollAreaEdgeMask={COMMAND_PREVIEW_EDGE_MASK}
                showMessageActions={false}
                workspaceId={workspaceId}
              />
            </InlineTaskLinkAdapterProvider>
          </div>
        )}
        <div
          ref={highlightOverlayRef}
          aria-hidden="true"
          className="comma-task-preview-search-highlight-overlay"
          data-slot={TASK_PREVIEW_SEARCH_HIGHLIGHT_OVERLAY}
        />
      </div>
    </section>
  );
}

const ignoreMessageAction = (_clientRequestId: string) => {};

function TaskConversationPreviewSkeleton({ label }: { label: string }) {
  return (
    <output
      aria-label={label}
      className="flex size-full flex-col gap-2xl px-lg py-xl motion-safe:animate-pulse"
      data-testid="task-conversation-preview-loading"
    >
      <div className="flex flex-col items-start gap-sm">
        <span className="h-3 w-2/3 rounded-full bg-quaternary" />
        <span className="h-3 w-1/2 rounded-full bg-quaternary" />
      </div>
      <div className="flex flex-col items-start gap-sm">
        <span className="h-3 w-5/6 rounded-full bg-quaternary" />
        <span className="h-3 w-3/4 rounded-full bg-quaternary" />
        <span className="h-3 w-2/5 rounded-full bg-quaternary" />
      </div>
      <div className="flex flex-col items-start gap-sm">
        <span className="h-3 w-3/5 rounded-full bg-quaternary" />
        <span className="h-3 w-1/3 rounded-full bg-quaternary" />
      </div>
    </output>
  );
}

function isAbortError(error: unknown) {
  return (
    typeof error === "object" &&
    error !== null &&
    "name" in error &&
    error.name === "AbortError"
  );
}
