import { formatNumber } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  memo,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type MouseEvent as ReactMouseEvent,
  type ReactElement,
  type ReactNode,
} from "react";
import { uiClock } from "../../clock";
import { Button } from "../Button";
import { FileTypeIcon } from "../file-type-icon";
import {
  ArrowUpIcon,
  ArrowUpRightIcon,
  ChatBubbleIcon,
  HistoryIcon,
  ImageIcon,
  MergedIcon,
  PullRequestClosedIcon,
  PullRequestIcon,
} from "../icons";
import { taskCardSelected, taskCardSurface } from "../task-board/styles";
import { TaskProgressText } from "../task-board/TaskProgressText";
import { taskStatusIcon } from "../task-workspace/TaskSummaryCard";
import { useTaskProgress } from "../task-workspace/taskProgress";
import type { TaskStatusBucket } from "../task-workspace/taskStatus";
import { cx, isImeKeyEvent } from "../utils";
import {
  formatFullFeedTime,
  formatRelativeFeedTime,
  normalizeEpochMs,
  sortMilestonesNewestFirst,
} from "./feedTime";
import { useHorizontalDragScroll } from "./useHorizontalDragScroll";
import type {
  TaskFeedEntry,
  TaskFeedFile,
  TaskFeedMedia,
  TaskFeedMilestone,
  TaskFeedPullRequest,
} from "./types";

const DEFAULT_VISIBLE_MILESTONES = 1;

export interface TaskFeedEntryRowProps {
  activeMessageId?: string | undefined;
  defaultExpanded?: boolean | undefined;
  defaultReplyOpen?: boolean | undefined;
  entry: TaskFeedEntry;
  expanded?: boolean | undefined;
  onApproveEntry?: ((entry: TaskFeedEntry) => Promise<void> | void) | undefined;
  onExpandedChange?: ((expanded: boolean) => void) | undefined;
  onOpenFullTask?: ((entry: TaskFeedEntry, messageId?: string) => void) | undefined;
  onReplyEntry?:
    | ((entry: TaskFeedEntry, text: string) => Promise<void> | void)
    | undefined;
  onSelectEntry?: ((entry: TaskFeedEntry, messageId?: string) => void) | undefined;
  onSelectMilestone?: ((entry: TaskFeedEntry, messageId: string) => void) | undefined;
  renderFile?:
    | ((
        file: TaskFeedFile,
        entry: TaskFeedEntry,
        defaultNode: ReactElement
      ) => ReactNode)
    | undefined;
  renderMedia?:
    | ((media: readonly TaskFeedMedia[], entry: TaskFeedEntry) => ReactNode)
    | undefined;
  renderPullRequest?:
    | ((
        pullRequest: TaskFeedPullRequest,
        entry: TaskFeedEntry,
        defaultNode: ReactElement
      ) => ReactNode)
    | undefined;
  selected?: boolean | undefined;
  unread?: boolean | undefined;
}

function primaryFeedCopy(entry: TaskFeedEntry): string {
  const outcome = entry.outcomeText?.trim();
  if (outcome) return outcome;
  const trigger = entry.triggerText?.trim();
  if (trigger) return trigger;
  return "";
}

function avatarSurfaceClass(status: TaskStatusBucket): string {
  switch (status) {
    case "needs_review":
      return "bg-yellow-500/12";
    case "in_progress":
      return "bg-tertiary";
    case "done":
      return "bg-success-500/12";
    case "cancelled":
      return "bg-error-500/12";
    default:
      return "bg-tertiary";
  }
}

/** Fades whichever edge of a horizontal strip still has content past it. */
function stripEdgeFadeClass(left: boolean, right: boolean): string {
  if (left && right) {
    return "[mask-image:linear-gradient(to_right,transparent,black_var(--spacing-xl),black_calc(100%-var(--spacing-xl)),transparent)]";
  }
  if (left) {
    return "[mask-image:linear-gradient(to_right,transparent,black_var(--spacing-xl))]";
  }
  if (right) {
    return "[mask-image:linear-gradient(to_left,transparent,black_var(--spacing-xl))]";
  }
  return "";
}

const STRIP_BLEED_CLASS =
  "-mr-lg pr-lg flex flex-nowrap overflow-x-auto overscroll-x-contain [scrollbar-width:none] [&::-webkit-scrollbar]:hidden";

function isDuplicateStepText(liveText: string, milestoneTitle: string): boolean {
  const a = liveText.trim().toLowerCase();
  const b = milestoneTitle.trim().toLowerCase();
  if (!a || !b) return false;
  return a === b || a.startsWith(b) || b.startsWith(a);
}

function pullRequestIcon(state: TaskFeedPullRequest["state"]) {
  if (state === "merged")
    return <MergedIcon aria-hidden className="size-4 shrink-0 text-tertiary" />;
  if (state === "closed")
    return (
      <PullRequestClosedIcon aria-hidden className="size-4 shrink-0 text-tertiary" />
    );
  return <PullRequestIcon aria-hidden className="size-4 shrink-0 text-tertiary" />;
}

function DefaultMediaStrip({ media }: { media: readonly TaskFeedMedia[] }) {
  const single = media.length === 1;
  const stripRef = useRef<HTMLDivElement | null>(null);
  const { canScroll, dragging, handlers, scrolledLeft, scrollableRight } =
    useHorizontalDragScroll(stripRef);

  return (
    <div
      className={cx(
        single
          ? "mt-lg flex min-w-0 max-w-full"
          : cx("relative mt-lg gap-md", STRIP_BLEED_CLASS),
        !single && stripEdgeFadeClass(scrolledLeft, scrollableRight),
        !single && canScroll
          ? dragging
            ? "cursor-grabbing select-none"
            : "cursor-grab"
          : ""
      )}
      data-slot="task-feed-media"
      ref={stripRef}
      {...(!single ? handlers : {})}
    >
      {media.map((item) => (
        <div
          className={cx(
            "flex shrink-0 items-center gap-sm border border-secondary bg-secondary/35 px-md py-md text-xs text-tertiary",
            single
              ? "min-h-24 w-full max-w-[340px] rounded-xl"
              : "h-[144px] w-[192px] rounded-xl"
          )}
          data-slot="task-feed-media-cell"
          key={item.attachmentId}
        >
          <ImageIcon aria-hidden className="size-4 shrink-0 text-quaternary" />
          <span className="min-w-0 truncate">{item.filename ?? item.attachmentId}</span>
        </div>
      ))}
    </div>
  );
}

interface VisibleThreadStep {
  id: string;
  isLive?: boolean;
  messageId?: string | undefined;
  ms?: number | undefined;
  relTime?: string | undefined;
  fullTime?: string | undefined;
  title: string;
}

export const TaskFeedEntryRow = memo(function TaskFeedEntryRow({
  activeMessageId,
  defaultExpanded = false,
  defaultReplyOpen = false,
  entry,
  expanded: controlledExpanded,
  onApproveEntry,
  onExpandedChange,
  onOpenFullTask,
  onReplyEntry,
  onSelectEntry,
  onSelectMilestone,
  renderFile,
  renderMedia,
  renderPullRequest,
  selected = false,
  unread = false,
}: TaskFeedEntryRowProps) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const liveStep = useTaskProgress(entry.conversationId);
  const [internalExpanded, setInternalExpanded] = useState(defaultExpanded);
  const expanded = controlledExpanded ?? internalExpanded;
  const [replyOpen, setReplyOpen] = useState(defaultReplyOpen);
  // The composer stays mounted while it leaves, and only a pointer press animates it.
  const [replyMounted, setReplyMounted] = useState(defaultReplyOpen);
  const [replyAnimated, setReplyAnimated] = useState(false);
  const [replyText, setReplyText] = useState("");
  const [replySubmitting, setReplySubmitting] = useState(false);
  const [approvePending, setApprovePending] = useState(false);
  const replyInputRef = useRef<HTMLInputElement | null>(null);
  const replyButtonRef = useRef<HTMLButtonElement | null>(null);
  const replyRevealRef = useRef<HTMLDivElement | null>(null);
  const replyComposerRef = useRef<HTMLDivElement | null>(null);
  const dismissedReplyClickEventRef = useRef<globalThis.MouseEvent | null>(null);
  const attachmentsRef = useRef<HTMLDivElement | null>(null);
  const attachmentsDrag = useHorizontalDragScroll(attachmentsRef);
  const earlierRegionId = useId();

  const changeReplyOpen = useCallback(
    (next: boolean, animated: boolean, returnFocus = true) => {
      setReplyAnimated(animated);
      if (next) {
        setReplyMounted(true);
      } else {
        const input = replyInputRef.current;
        if (input && document.activeElement === input) {
          if (returnFocus) {
            replyButtonRef.current?.focus({ preventScroll: true });
          } else {
            input.blur();
          }
        }
      }
      setReplyOpen(next);
    },
    []
  );

  useEffect(() => {
    if (!replyOpen) return undefined;
    let pointerDownInside = false;
    const isInsideReply = (target: EventTarget | null) =>
      target instanceof Node &&
      Boolean(
        replyComposerRef.current?.contains(target) ||
        replyButtonRef.current?.contains(target)
      );
    const onPointerDown = (event: globalThis.PointerEvent) => {
      pointerDownInside = isInsideReply(event.target);
    };
    const onPointerCancel = () => {
      pointerDownInside = false;
    };
    const onClick = (event: globalThis.MouseEvent) => {
      const startedInside = pointerDownInside;
      pointerDownInside = false;
      if (startedInside || replySubmitting) return;
      if (isInsideReply(event.target)) return;
      if (
        event.target instanceof Element &&
        event.target.closest('[data-slot="scroll-area-scrollbar"]')
      ) {
        return;
      }
      const selection = window.getSelection?.();
      if (
        selection &&
        !selection.isCollapsed &&
        selection.toString().trim().length > 0
      ) {
        return;
      }
      dismissedReplyClickEventRef.current = event;
      changeReplyOpen(false, event.detail > 0, false);
    };
    document.addEventListener("pointerdown", onPointerDown, true);
    document.addEventListener("pointercancel", onPointerCancel, true);
    document.addEventListener("click", onClick, true);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown, true);
      document.removeEventListener("pointercancel", onPointerCancel, true);
      document.removeEventListener("click", onClick, true);
    };
  }, [changeReplyOpen, replyOpen, replySubmitting]);

  useEffect(() => {
    if (!replyOpen) return undefined;
    replyInputRef.current?.focus({ preventScroll: replyAnimated });
    const reveal = replyRevealRef.current;
    if (!replyAnimated || !reveal) return undefined;
    let current = true;
    void Promise.all(
      reveal.getAnimations({ subtree: true }).map((a) => a.finished)
    ).then(
      () => {
        if (!current) return;
        const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
        reveal.scrollIntoView({
          behavior: reduced ? "auto" : "smooth",
          block: "nearest",
        });
      },
      () => undefined
    );
    return () => {
      current = false;
    };
  }, [replyAnimated, replyOpen]);

  // Reads the transitions the closed state just started, then unmounts after them.
  useLayoutEffect(() => {
    if (replyOpen || !replyMounted) return undefined;
    const animations = replyRevealRef.current?.getAnimations({ subtree: true }) ?? [];
    if (animations.length === 0) {
      setReplyMounted(false);
      return undefined;
    }
    let current = true;
    void Promise.all(animations.map((animation) => animation.finished)).then(
      () => {
        if (current) setReplyMounted(false);
      },
      () => undefined
    );
    return () => {
      current = false;
    };
  }, [replyMounted, replyOpen]);

  const setExpanded = useCallback(
    (next: boolean) => {
      if (controlledExpanded === undefined) setInternalExpanded(next);
      onExpandedChange?.(next);
    },
    [controlledExpanded, onExpandedChange]
  );

  const nowMs = uiClock.now();
  const occurredAtMs = normalizeEpochMs(entry.occurredAt);
  const relativeOccurredAt = useMemo(
    () => formatRelativeFeedTime(occurredAtMs, nowMs, locale, messages),
    [locale, messages, nowMs, occurredAtMs]
  );
  const fullOccurredAt = useMemo(
    () => formatFullFeedTime(occurredAtMs, locale),
    [locale, occurredAtMs]
  );

  const sortedMilestones = useMemo(
    () => sortMilestonesNewestFirst(entry.milestones),
    [entry.milestones]
  );

  const showLiveStep =
    entry.statusBucket === "in_progress" && Boolean(liveStep?.trim());

  // Dedupe liveStep against newest milestone so identical copy is never printed twice.
  const { mergedLiveMessageId, remainingMilestones } = useMemo(() => {
    if (
      showLiveStep &&
      liveStep &&
      sortedMilestones.length > 0 &&
      isDuplicateStepText(liveStep, sortedMilestones[0]!.title)
    ) {
      return {
        mergedLiveMessageId: sortedMilestones[0]!.messageId,
        remainingMilestones: sortedMilestones.slice(1),
      };
    }
    return {
      mergedLiveMessageId: undefined,
      remainingMilestones: sortedMilestones,
    };
  }, [liveStep, showLiveStep, sortedMilestones]);

  // Show ONLY 1 latest step by default: if liveStep is active, show liveStep alone and collapse all completed milestones;
  // otherwise show only the single newest milestone.
  const collapsedMilestoneCount = showLiveStep ? 0 : DEFAULT_VISIBLE_MILESTONES;
  const topMilestones = useMemo(
    () => remainingMilestones.slice(0, collapsedMilestoneCount),
    [collapsedMilestoneCount, remainingMilestones]
  );
  const earlierMilestones = useMemo(
    () => remainingMilestones.slice(collapsedMilestoneCount),
    [collapsedMilestoneCount, remainingMilestones]
  );

  const hasEarlierSteps = earlierMilestones.length > 0;
  const primaryCopy = primaryFeedCopy(entry);

  const visibleThreadSteps = useMemo<VisibleThreadStep[]>(() => {
    const toStep = (milestone: TaskFeedMilestone, idx: number): VisibleThreadStep => {
      const ms =
        milestone.at !== undefined ? normalizeEpochMs(milestone.at) : undefined;
      const relTime =
        ms !== undefined
          ? formatRelativeFeedTime(ms, nowMs, locale, messages)
          : undefined;
      return {
        id: `${milestone.messageId ?? "m"}-${milestone.at ?? idx}-${milestone.title}`,
        messageId: milestone.messageId,
        ms,
        // The newest step usually happened when the post did: one time is enough.
        relTime: idx === 0 && relTime === relativeOccurredAt ? undefined : relTime,
        fullTime: ms !== undefined ? formatFullFeedTime(ms, locale) : undefined,
        title: milestone.title,
      };
    };

    const items: VisibleThreadStep[] = [];
    if (showLiveStep && liveStep) {
      items.push({
        id: "live-step",
        isLive: true,
        messageId: mergedLiveMessageId,
        relTime: messages.task_feed_now(),
        title: liveStep.trim(),
      });
    }
    const activeMilestones = expanded ? remainingMilestones : topMilestones;
    for (let i = 0; i < activeMilestones.length; i += 1) {
      items.push(toStep(activeMilestones[i]!, i));
    }
    return items;
  }, [
    expanded,
    liveStep,
    locale,
    mergedLiveMessageId,
    messages,
    nowMs,
    relativeOccurredAt,
    remainingMilestones,
    showLiveStep,
    topMilestones,
  ]);

  const hasTimeline = visibleThreadSteps.length > 0;

  const prStateLabel = useMemo(() => {
    if (!entry.pullRequest) return "";
    switch (entry.pullRequest.state) {
      case "merged":
        return messages.task_feed_pr_merged();
      case "closed":
        return messages.task_feed_pr_closed();
      case "draft":
        return messages.task_feed_pr_draft();
      case "open":
        return messages.task_feed_pr_open();
    }
  }, [entry.pullRequest, messages]);

  const handleApprove = useCallback(async () => {
    if (!onApproveEntry || approvePending) return;
    setApprovePending(true);
    try {
      await onApproveEntry(entry);
    } finally {
      setApprovePending(false);
    }
  }, [approvePending, entry, onApproveEntry]);

  const handleReplySubmit = useCallback(
    async (animated: boolean) => {
      const trimmed = replyText.trim();
      if (!trimmed || !onReplyEntry || replySubmitting) return;
      setReplySubmitting(true);
      try {
        await onReplyEntry(entry, trimmed);
        setReplyText("");
        changeReplyOpen(false, animated);
      } catch {
        // The owner reports the failure; the draft stays so it can be sent again.
        replyInputRef.current?.focus();
      } finally {
        setReplySubmitting(false);
      }
    },
    [changeReplyOpen, entry, onReplyEntry, replySubmitting, replyText]
  );

  const handleReplyKeyDown = useCallback(
    (event: KeyboardEvent<HTMLInputElement>) => {
      if (isImeKeyEvent(event.nativeEvent)) return;
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        changeReplyOpen(false, false);
        return;
      }
      if (event.key === "Enter" && !event.shiftKey) {
        event.preventDefault();
        void handleReplySubmit(false);
      }
    },
    [changeReplyOpen, handleReplySubmit]
  );

  const canApprove =
    entry.statusBucket === "needs_review" &&
    entry.reviewVersion !== undefined &&
    Boolean(onApproveEntry);
  const showActionsBar = Boolean(
    onReplyEntry || entry.milestoneCount > 0 || canApprove
  );

  const handleCardClick = useCallback(
    (event: ReactMouseEvent<HTMLElement>) => {
      if (dismissedReplyClickEventRef.current === event.nativeEvent) {
        dismissedReplyClickEventRef.current = null;
        return;
      }
      if (!onSelectEntry || replyOpen) return;
      const target = event.target;
      if (!(target instanceof Element)) return;
      if (
        target.closest(
          'button, a, input, textarea, select, [role="button"], [role="link"], [data-slot="task-feed-media"], [data-slot="task-feed-attachments"], [data-slot="task-feed-inline-reply"]'
        )
      ) {
        return;
      }
      const selection = window.getSelection?.();
      if (
        selection &&
        !selection.isCollapsed &&
        selection.toString().trim().length > 0
      ) {
        return;
      }
      onSelectEntry(entry);
    },
    [entry, onSelectEntry, replyOpen]
  );

  return (
    // oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-noninteractive-element-interactions
    <article
      className={cx(
        "relative grid grid-cols-[1.75rem_minmax(0,1fr)] gap-x-md px-lg pt-xl pb-lg transition-shadow @max-md:pt-lg @max-md:pb-md",
        taskCardSurface,
        selected ? taskCardSelected : "",
        onSelectEntry ? "cursor-pointer" : ""
      )}
      data-entry-id={entry.id}
      data-occurred-at={occurredAtMs}
      data-selected={selected ? "true" : "false"}
      data-slot="task-feed-entry"
      data-status={entry.statusBucket}
      onClick={onSelectEntry ? handleCardClick : undefined}
    >
      {/* Status avatar beside one content column, as in a message feed. */}
      <span
        aria-hidden
        className={cx(
          "flex size-7 shrink-0 items-center justify-center rounded-full [&_svg]:size-4",
          avatarSurfaceClass(entry.statusBucket)
        )}
        data-slot="task-feed-avatar"
      >
        {taskStatusIcon(entry.statusBucket)}
      </span>

      <div className="min-w-0">
        <div className="min-w-0">
          {/* The time follows the title; the open action holds the right edge. */}
          <div className="flex items-start gap-sm">
            {/* Title and time share one inline run, so a wrapped title keeps the time beside its last word. */}
            <div className="line-clamp-2 min-w-0 flex-1 pt-xs text-sm break-words">
              {/* oxlint-disable jsx-a11y/prefer-tag-over-role -- <button> is atomic inline-block even with display:inline, which drops the timestamp to a new line when the title wraps. */}
              <span
                className="cursor-pointer font-semibold text-primary focus-visible:underline focus-visible:outline-none"
                data-slot="task-feed-title"
                onClick={(event) => {
                  event.stopPropagation();
                  onSelectEntry?.(entry);
                }}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    event.stopPropagation();
                    onSelectEntry?.(entry);
                  }
                }}
                role="button"
                tabIndex={0}
                title={entry.taskTitle}
              >
                {entry.taskTitle}
              </span>
              {/* oxlint-enable jsx-a11y/prefer-tag-over-role */}{" "}
              <span className="inline-flex items-baseline gap-sm text-xs whitespace-nowrap tabular-nums text-quaternary">
                <time
                  dateTime={
                    occurredAtMs !== undefined
                      ? new Date(occurredAtMs).toISOString()
                      : undefined
                  }
                  title={fullOccurredAt}
                >
                  {relativeOccurredAt}
                </time>
                {unread ? (
                  <span
                    aria-hidden
                    className="size-1.5 shrink-0 self-center rounded-full bg-brand-solid"
                    data-slot="task-feed-unread-dot"
                  />
                ) : null}
              </span>
            </div>

            {onOpenFullTask ? (
              <button
                aria-label={messages.task_feed_open_full_task()}
                className="comma-task-feed-icon-action -mr-sm -mt-xxs inline-flex size-8 shrink-0 cursor-pointer items-center justify-center rounded-full bg-transparent text-tertiary focus-visible:shadow-focus-gray focus-visible:outline-none"
                data-no-press-feedback=""
                data-slot="task-feed-open-full-action"
                onClick={() => onOpenFullTask(entry)}
                title={messages.task_feed_open_full_task()}
                type="button"
              >
                <ArrowUpRightIcon aria-hidden className="size-4" />
              </button>
            ) : null}
          </div>

          {/* The whole post opens on click, so its text stays selectable. */}
          {primaryCopy ? (
            <p
              className="m-0 mt-xs line-clamp-3 text-sm break-words text-secondary"
              data-slot="task-feed-body"
            >
              {primaryCopy}
            </p>
          ) : null}

          {/* Compact Frameless Media Strip */}
          {entry.media.length > 0 ? (
            renderMedia ? (
              <div className="mt-lg" data-slot="task-feed-media">
                {renderMedia(entry.media, entry)}
              </div>
            ) : (
              <DefaultMediaStrip media={entry.media} />
            )
          ) : null}

          {/* Quiet Monochrome Inline Attachment Pills */}
          {entry.pullRequest || entry.files.length > 0 ? (
            <div
              className={cx(
                "relative mt-lg items-center gap-sm py-xxs",
                STRIP_BLEED_CLASS,
                stripEdgeFadeClass(
                  attachmentsDrag.scrolledLeft,
                  attachmentsDrag.scrollableRight
                ),
                attachmentsDrag.canScroll
                  ? attachmentsDrag.dragging
                    ? "cursor-grabbing select-none"
                    : "cursor-grab"
                  : ""
              )}
              data-slot="task-feed-attachments"
              ref={attachmentsRef}
              {...attachmentsDrag.handlers}
            >
              {entry.pullRequest
                ? (() => {
                    const prNode = (
                      <a
                        className="inline-flex h-8 shrink-0 items-center gap-sm rounded-full border border-primary bg-todo-kanban-bg-card-primary px-lg text-sm font-medium text-primary shadow-xs transition-colors hover:bg-secondary-hover focus-visible:shadow-focus-gray focus-visible:outline-none"
                        data-slot="task-feed-pr"
                        href={entry.pullRequest.url}
                        rel="noreferrer"
                        target="_blank"
                      >
                        {pullRequestIcon(entry.pullRequest.state)}
                        <span className="tabular-nums">
                          #{entry.pullRequest.number}
                        </span>
                        <span className="font-normal text-tertiary">
                          {prStateLabel}
                        </span>
                      </a>
                    );
                    return renderPullRequest ? (
                      <span className="inline-flex shrink-0">
                        {renderPullRequest(entry.pullRequest, entry, prNode)}
                      </span>
                    ) : (
                      prNode
                    );
                  })()
                : null}
              {entry.files.map((file) => {
                const fileNode = (
                  <button
                    className="inline-flex h-8 max-w-60 shrink-0 cursor-pointer items-center gap-sm rounded-full border border-primary bg-todo-kanban-bg-card-primary px-lg text-sm text-primary shadow-xs transition-colors hover:bg-secondary-hover focus-visible:outline-none focus-visible:shadow-focus-gray"
                    data-slot="task-feed-file"
                    key={file.name}
                    onClick={() => onSelectEntry?.(entry, entry.outcomeMessageId)}
                    title={file.name}
                    type="button"
                  >
                    <FileTypeIcon
                      className="size-4 shrink-0"
                      fileName={file.name}
                      mimeType={file.mimeType}
                    />
                    <span className="min-w-0 truncate">{file.name}</span>
                  </button>
                );
                return renderFile ? (
                  <span className="inline-flex shrink-0" key={file.name}>
                    {renderFile(file, entry, fileNode)}
                  </span>
                ) : (
                  fileNode
                );
              })}
            </div>
          ) : null}
        </div>

        {/* Steps sit in a quiet inset block, newest first. */}
        {hasTimeline ? (
          <div
            className="mt-lg rounded-lg bg-tertiary"
            data-slot="task-feed-timeline"
            id={earlierRegionId}
          >
            <ul className="m-0 flex flex-col p-0">
              {visibleThreadSteps.map((step, index) => {
                const isHighlighted =
                  Boolean(step.messageId) && activeMessageId === step.messageId;
                const isRunningLatest =
                  entry.statusBucket === "in_progress" && index === 0;
                const isPulsingDot = isRunningLatest || Boolean(step.isLive);
                const isMultiLine = expanded && !isRunningLatest;
                const dotNode = (
                  <span className="flex justify-center">
                    {isPulsingDot ? (
                      <span
                        aria-hidden
                        className={cx(
                          "size-2 shrink-0 rounded-full bg-brand-solid",
                          isMultiLine ? "mt-1.5" : ""
                        )}
                      />
                    ) : (
                      <span
                        aria-hidden
                        className={cx(
                          "size-1.5 shrink-0 rounded-full border transition-colors",
                          isMultiLine ? "mt-[7px]" : "",
                          isHighlighted
                            ? "border-brand-solid bg-brand-solid"
                            : "border-[var(--color-fg-quinary)] bg-tertiary"
                        )}
                      />
                    )}
                  </span>
                );
                const contentNode = (
                  <span className="flex min-w-0 items-baseline justify-between gap-md">
                    {isRunningLatest ? (
                      <span
                        className="min-w-0 flex-1 overflow-hidden font-medium"
                        title={step.title}
                      >
                        <TaskProgressText className="comma-shiny-text">
                          {step.title}
                        </TaskProgressText>
                      </span>
                    ) : (
                      <span
                        className={cx(
                          "min-w-0 flex-1",
                          expanded ? "break-words line-clamp-2" : "truncate"
                        )}
                        title={step.title}
                      >
                        {step.title}
                      </span>
                    )}
                    {step.relTime ? (
                      step.messageId && (onSelectMilestone || onSelectEntry) ? (
                        <time
                          className={cx(
                            "shrink-0 text-xs tabular-nums",
                            step.isLive ? "text-tertiary" : "text-quaternary"
                          )}
                          dateTime={
                            step.ms !== undefined
                              ? new Date(step.ms).toISOString()
                              : undefined
                          }
                          title={step.fullTime}
                        >
                          {step.relTime}
                        </time>
                      ) : (
                        <span
                          className={cx(
                            "shrink-0 text-xs tabular-nums",
                            step.isLive ? "text-tertiary" : "text-quaternary"
                          )}
                        >
                          {step.relTime}
                        </span>
                      )
                    ) : null}
                  </span>
                );

                const isClickableStep = Boolean(
                  (step.messageId && onSelectMilestone) || onSelectEntry
                );

                return (
                  <li
                    className="group list-none"
                    data-milestone-at={step.ms ?? ""}
                    data-milestone-id={step.messageId ?? ""}
                    data-shimmer={isRunningLatest ? "true" : undefined}
                    data-slot={
                      step.isLive ? "task-feed-live-step" : "task-feed-milestone"
                    }
                    key={step.id}
                  >
                    {isClickableStep ? (
                      <button
                        className={cx(
                          "grid w-full cursor-pointer grid-cols-[10px_minmax(0,1fr)] gap-x-sm px-md py-xs text-left text-sm transition-colors group-first:rounded-t-lg group-last:rounded-b-lg focus-visible:shadow-focus-gray focus-visible:outline-none",
                          isMultiLine ? "items-start" : "items-center",
                          isHighlighted
                            ? "bg-quaternary font-medium text-primary"
                            : isRunningLatest || step.isLive
                              ? "font-medium hover:bg-quaternary-hover"
                              : "text-secondary hover:bg-quaternary-hover hover:text-primary"
                        )}
                        data-active-milestone={isHighlighted ? "true" : "false"}
                        onClick={() => {
                          if (step.messageId && onSelectMilestone) {
                            onSelectMilestone(entry, step.messageId);
                          } else {
                            onSelectEntry?.(entry, step.messageId);
                          }
                        }}
                        type="button"
                      >
                        {dotNode}
                        {contentNode}
                      </button>
                    ) : (
                      <div
                        className={cx(
                          "grid w-full grid-cols-[10px_minmax(0,1fr)] gap-x-sm px-md py-xs text-sm",
                          isMultiLine ? "items-start" : "items-center",
                          step.isLive ? "font-medium text-primary" : "text-secondary"
                        )}
                      >
                        {dotNode}
                        {contentNode}
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          </div>
        ) : null}

        {/* Actions and the inline reply share the content column. */}
        {showActionsBar || (replyMounted && onReplyEntry) ? (
          <div className="min-w-0">
            {showActionsBar ? (
              <div
                className="mt-md -ml-sm flex items-center justify-between gap-md"
                data-slot="task-feed-actions"
              >
                <div className="flex items-center gap-xs text-tertiary">
                  {onReplyEntry ? (
                    <button
                      aria-expanded={replyOpen}
                      aria-label={messages.task_feed_reply()}
                      className={cx(
                        "comma-task-feed-icon-action inline-flex size-8 cursor-pointer items-center justify-center rounded-full bg-transparent focus-visible:outline-none focus-visible:shadow-focus-gray",
                        replyOpen ? "text-primary" : "text-tertiary"
                      )}
                      data-active={replyOpen ? "true" : "false"}
                      data-no-press-feedback=""
                      data-slot="task-feed-reply-action"
                      onClick={(event) => changeReplyOpen(!replyOpen, event.detail > 0)}
                      ref={replyButtonRef}
                      title={messages.task_feed_reply()}
                      type="button"
                    >
                      <ChatBubbleIcon aria-hidden className="size-5" />
                    </button>
                  ) : null}

                  {entry.milestoneCount > 0 ? (
                    <button
                      aria-controls={hasEarlierSteps ? earlierRegionId : undefined}
                      aria-expanded={hasEarlierSteps ? expanded : undefined}
                      aria-label={
                        expanded
                          ? messages.task_feed_hide_earlier_steps()
                          : hasEarlierSteps
                            ? messages.task_feed_show_earlier_steps({
                                count: earlierMilestones.length,
                                formattedCount: formatNumber(
                                  earlierMilestones.length,
                                  locale
                                ),
                              })
                            : messages.task_feed_open_full_task()
                      }
                      className={cx(
                        "comma-task-feed-icon-action inline-flex h-8 cursor-pointer items-center gap-sm rounded-full bg-transparent px-sm text-sm font-medium tabular-nums focus-visible:outline-none focus-visible:shadow-focus-gray",
                        expanded && hasEarlierSteps ? "text-primary" : "text-tertiary"
                      )}
                      data-active={expanded && hasEarlierSteps ? "true" : "false"}
                      data-no-press-feedback=""
                      data-slot="task-feed-steps-action"
                      onClick={() => {
                        if (hasEarlierSteps) {
                          setExpanded(!expanded);
                        } else {
                          onSelectEntry?.(entry);
                        }
                      }}
                      title={
                        expanded
                          ? messages.task_feed_hide_earlier_steps()
                          : hasEarlierSteps
                            ? messages.task_feed_show_earlier_steps({
                                count: earlierMilestones.length,
                                formattedCount: formatNumber(
                                  earlierMilestones.length,
                                  locale
                                ),
                              })
                            : messages.task_feed_open_full_task()
                      }
                      type="button"
                    >
                      <HistoryIcon aria-hidden className="size-5" />
                      <span>{formatNumber(entry.milestoneCount, locale)}</span>
                    </button>
                  ) : null}
                </div>

                {canApprove ? (
                  <Button
                    className="h-6 px-sm py-0 text-xs"
                    data-slot="task-feed-approve-action"
                    hierarchy="secondary-gray"
                    isDisabled={approvePending}
                    onPress={() => void handleApprove()}
                    size="xs"
                  >
                    {messages.task_feed_approve()}
                  </Button>
                ) : null}
              </div>
            ) : null}

            {/* Inline Threads-style Quick Reply Composer right below Bottom Action Bar */}
            {replyMounted && onReplyEntry ? (
              <div
                className="comma-task-feed-reply"
                data-animated={replyAnimated ? "true" : "false"}
                data-state={replyOpen ? "open" : "closed"}
                inert={!replyOpen}
                ref={replyRevealRef}
              >
                <div className="comma-task-feed-reply__clip">
                  <div className="comma-task-feed-reply__content">
                    <div
                      className="flex items-center gap-md rounded-xl border border-primary bg-secondary/35 py-sm pr-sm pl-lg"
                      data-slot="task-feed-inline-reply"
                      ref={replyComposerRef}
                    >
                      <input
                        aria-label={messages.task_feed_reply_placeholder()}
                        className="min-w-0 flex-1 border-0 bg-transparent text-sm text-primary placeholder:text-placeholder focus:outline-none"
                        readOnly={replySubmitting}
                        onChange={(event) => setReplyText(event.target.value)}
                        onKeyDown={handleReplyKeyDown}
                        placeholder={messages.task_feed_reply_placeholder()}
                        ref={replyInputRef}
                        type="text"
                        value={replyText}
                      />
                      <button
                        aria-label={messages.task_feed_reply_send()}
                        className={cx(
                          "inline-flex size-6 shrink-0 cursor-pointer items-center justify-center rounded-full transition-colors disabled:cursor-not-allowed focus-visible:outline-none focus-visible:shadow-focus-gray",
                          !replySubmitting && replyText.trim().length > 0
                            ? "bg-button-primary-bg text-ai-input-panel-icon-fg hover:bg-button-primary-bg-hover"
                            : "bg-ai-input-panel-bg-disabled text-ai-input-panel-icon-disabled"
                        )}
                        disabled={replySubmitting || replyText.trim().length === 0}
                        onClick={(event) => void handleReplySubmit(event.detail > 0)}
                        type="button"
                      >
                        <ArrowUpIcon aria-hidden className="size-3.5" />
                      </button>
                    </div>
                  </div>
                </div>
              </div>
            ) : null}
          </div>
        ) : null}
      </div>
    </article>
  );
});
