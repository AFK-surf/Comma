import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { cx } from "@comma/ui/components/utils";
import { spacing } from "@comma/ui/tokens";
import { useId, useRef, useState } from "react";
import type { ChatMessage } from "@comma/core/chat";
import { ConversationThread } from "../chat/thread/ConversationThread";
import {
  InlineTaskLinkAdapterProvider,
  passiveInlineTaskLinkAdapter,
} from "../chat/thread/inline/MessageInlineElements";
import {
  useTaskConversation,
  type TaskConversationPreviewTarget,
} from "./taskConversationPreviewLoader";
import {
  TASK_PREVIEW_SEARCH_HIGHLIGHT_OVERLAY,
  usePreviewSearchHighlight,
} from "./previewSearchHighlight";

type PreviewState =
  | { status: "error" }
  | { status: "loading" }
  | { messages: ChatMessage[]; status: "ready" };

export type TaskConversationPreviewProps = {
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
  const [retry, setRetry] = useState(0);
  const { conversationId, groupId, title, workspaceId } = task;
  const answer = useTaskConversation(task, messageLimit, retry);
  // What the core read last stays shown while it reads again, or after a read failed.
  const visibleState: PreviewState = answer?.messages
    ? { messages: answer.messages, status: "ready" }
    : answer?.status === "failed"
      ? { status: "error" }
      : { status: "loading" };
  usePreviewSearchHighlight(contentRef, highlightOverlayRef, searchQuery);

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
        ) : visibleState.messages.length === 0 ? (
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
                live
                conversationId={conversationId}
                contentMode="display-only"
                groupId={groupId}
                messages={visibleState.messages}
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
