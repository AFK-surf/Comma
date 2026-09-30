import { useCommaMessages } from "@comma/i18n/react";
import {
  useCallback,
  useLayoutEffect,
  useRef,
  type ReactNode,
  type UIEvent,
} from "react";
import { AiInput, type AiInputProps } from "../ai-input";
import { ChainLinkIcon, ChevronDoubleRightIcon, ExpandSimpleIcon } from "../icons";
import { ScrollArea } from "../scroll-area";
import { cx } from "../utils";

export interface TaskChatPanelProps {
  title: ReactNode;
  children: ReactNode;
  aiInputProps: AiInputProps;
  className?: string;
  onClose: () => void;
  onCopyLink?: (() => void) | undefined;
  onExpand?: (() => void) | undefined;
}

const toolbarButton =
  "inline-flex size-7 shrink-0 items-center justify-center rounded-sm border-0 bg-transparent p-xs text-secondary hover:bg-sidebar-bg-item hover:text-primary focus-visible:outline-none focus-visible:shadow-focus-gray";
const stickToEndThreshold = 24;

/**
 * Figma Comma App 439:7675 — Tasks detail chat that opens beside the board.
 * The owning feature supplies data and actions; this component owns the exact
 * right-panel structure, scrolling, toolbar, and composer placement.
 */
export const TaskChatPanel = ({
  title,
  children,
  aiInputProps,
  className,
  onClose,
  onCopyLink,
  onExpand,
}: TaskChatPanelProps) => {
  const messages = useCommaMessages();
  const viewportRef = useRef<HTMLDivElement | null>(null);
  const stickToEndRef = useRef(true);
  const scrollToEndIfNeeded = useCallback(() => {
    const viewport = viewportRef.current;
    if (!viewport || !stickToEndRef.current) return;
    viewport.scrollTop = Math.max(0, viewport.scrollHeight - viewport.clientHeight);
  }, []);
  const handleScroll = useCallback((event: UIEvent<HTMLDivElement>) => {
    const viewport = event.currentTarget;
    const distanceToEnd =
      viewport.scrollHeight - viewport.clientHeight - viewport.scrollTop;
    stickToEndRef.current = distanceToEnd <= stickToEndThreshold;
  }, []);

  useLayoutEffect(() => {
    scrollToEndIfNeeded();
  }, [children, scrollToEndIfNeeded]);

  return (
    <aside
      aria-label={messages.task_chat_label()}
      className={cx(
        "flex h-full min-h-0 min-w-0 flex-col border-l-[0.5px] border-primary bg-main-panel-bg",
        className
      )}
      data-slot="task-chat-panel"
    >
      <header className="flex h-10 shrink-0 items-center justify-between border-b-[0.5px] border-primary px-md">
        <div className="flex items-center gap-xs">
          <button
            aria-label={messages.task_close_chat()}
            className={toolbarButton}
            onClick={onClose}
            type="button"
          >
            <ChevronDoubleRightIcon className="size-5" />
          </button>
          <button
            aria-label={messages.task_open_chat()}
            className={toolbarButton}
            disabled={!onExpand}
            onClick={onExpand}
            type="button"
          >
            <ExpandSimpleIcon className="size-5" />
          </button>
        </div>
        <button
          aria-label={messages.task_copy_link()}
          className={toolbarButton}
          disabled={!onCopyLink}
          onClick={onCopyLink}
          type="button"
        >
          <ChainLinkIcon className="size-5" />
        </button>
      </header>

      <div className="flex min-h-0 flex-1 flex-col">
        <h2 className="m-0 shrink-0 px-lg pt-4xl text-xl font-medium leading-[30px] text-primary">
          {title}
        </h2>
        <ScrollArea
          className="min-h-0 flex-1"
          contentClassName="flex min-h-full flex-col gap-3xl px-3xl pb-3xl pt-4xl"
          edgeEffect="mask"
          edgeMask={{ endSize: 24, startSize: 24 }}
          onContentResize={scrollToEndIfNeeded}
          onScroll={handleScroll}
          orientation="vertical"
          ref={viewportRef}
          viewportProps={{
            role: "log",
            "aria-label": messages.task_conversation_label(),
          }}
        >
          {children}
        </ScrollArea>
        <div className="shrink-0 px-3xl pb-lg">
          <AiInput {...aiInputProps} />
        </div>
      </div>
    </aside>
  );
};
