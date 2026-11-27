import { formatNumber, taskStatusBucketLabel, taskStatusLabel } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { scheduleLayoutRead, uiClock } from "@comma/ui/clock";
import {
  BubbleAlertIcon,
  ChevronTopSmallIcon,
  GlobeIcon,
  HelpCircleIcon,
  LoaderIcon,
  MapPinIcon,
  PhoneDynamicIslandIcon,
  PuzzleIcon,
  SignInKeyIcon,
  TagLabelIcon,
  XIcon,
} from "@comma/ui/components/icons";
import { taskStatusIcon } from "@comma/ui/components/task-workspace";
import {
  TaskArchiveMenu,
  type TaskArchiveAction,
} from "@comma/ui/components/task-workspace/TaskArchiveMenu";
import { TitleSwap } from "@comma/ui/components/title-swap";
import {
  defaultRangeExtractor,
  useVirtualizer,
  type Range,
  type Rect,
} from "@tanstack/react-virtual";
import {
  memo,
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type RefObject,
} from "react";
import { Button as AriaButton } from "react-aria-components";
import { flushSync } from "react-dom";
import type { ChatAttentionCard, ChatAttentionCardKind } from "./useChatAttentionCards";
import type { ChatCreatedTask } from "./useChatCreatedTasks";

/** "chat" opens the Task's chat beside this one; "page" opens the Task itself. */
export type ChatTaskOpenTarget = "chat" | "page";
export type ChatDockPopoverKind = "attention" | "active";

type ActiveTaskFilter = "all" | "in_progress" | "loops";

type ChatTaskActions = {
  onArchive: (task: ChatCreatedTask) => Promise<void>;
  onDismiss: (task: ChatCreatedTask) => void;
  onOpen: (task: ChatCreatedTask, target: ChatTaskOpenTarget) => void;
  onReveal: (task: ChatCreatedTask) => void;
};

/** Rows on screen at once; past this the list scrolls inside the popover. */
const VISIBLE_ROWS = 5;

type RowGeometry = { block: number; gap: number };

/** Token geometry at the default font size, until the probe has been read. */
const DEFAULT_ROW_GEOMETRY: RowGeometry = { block: 28, gap: 2 };

const NO_ATTENTION_CARDS: readonly ChatAttentionCard[] = [];

function isActiveTask(task: ChatCreatedTask): boolean {
  return task.statusBucket === "in_progress" || task.statusBucket === "loops";
}

function cardKindIcon(kind: ChatAttentionCardKind) {
  switch (kind) {
    case "question":
      return <HelpCircleIcon aria-hidden className="comma-chat-dock-card-icon-warn" />;
    case "secret":
      return <SignInKeyIcon aria-hidden className="comma-chat-dock-card-icon-warn" />;
    case "login":
    case "oauth":
      return <GlobeIcon aria-hidden className="comma-chat-dock-card-icon-warn" />;
    case "location":
      return <MapPinIcon aria-hidden className="comma-chat-dock-card-icon-warn" />;
    case "phone":
      return (
        <PhoneDynamicIslandIcon
          aria-hidden
          className="comma-chat-dock-card-icon-warn"
        />
      );
    case "plugin":
      return <PuzzleIcon aria-hidden className="comma-chat-dock-card-icon-warn" />;
    case "labels":
      return <TagLabelIcon aria-hidden className="comma-chat-dock-card-icon-brand" />;
  }
}

function formatClock(seconds: number): string {
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

function DockCountdown({ expiresAt }: { expiresAt: number }) {
  const compute = () => Math.max(0, Math.ceil((expiresAt - uiClock.now()) / 1000));
  const [seconds, setSeconds] = useState(compute);
  useEffect(() => {
    setSeconds(compute());
    const stop = uiClock.every(1000, () => {
      const next = compute();
      setSeconds(next);
      if (next === 0) stop();
    });
    return stop;
    // `compute` reads only `expiresAt`.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [expiresAt]);

  if (seconds <= 0) return null;
  return (
    <span
      className="comma-chat-dock-countdown"
      data-soon={seconds <= 60 ? "true" : undefined}
      role="timer"
    >
      {formatClock(seconds)}
    </span>
  );
}

/**
 * Dual-bubble sticky dock pinned above the composer:
 *
 * 1. **Attention Focus Strip** (left): surfaces the highest-priority pending
 *    confirmation card (`QuestionCard`, `AgentRequestCard`, label proposals) or
 *    `needs_review` / `escalated` / failed Task right above the composer so it
 *    cannot be buried by message bursts. Multiple items show a `+N` trigger
 *    opening a floating popover with every pending item.
 * 2. **Active Tasks Pill** (right): compact capsule summarizing running Tasks
 *    and standing Loops, opening a floating virtualized popover on press.
 *
 * Both popovers float above the bar (`position: absolute`) instead of growing
 * the composer column, so opening or closing them never resizes the transcript
 * scrollport or triggers stick-to-bottom reflows.
 */
export const ChatTaskPanel = memo(function ChatTaskPanel({
  attentionCards = NO_ATTENTION_CARDS,
  defaultOpenPopover = null,
  items,
  onArchive,
  onDismiss,
  onOpen,
  onReveal,
  onRevealCard,
}: ChatTaskActions & {
  attentionCards?: readonly ChatAttentionCard[] | undefined;
  /** Optional initial open popover for deterministic tests. */
  defaultOpenPopover?: ChatDockPopoverKind | null | undefined;
  items: readonly ChatCreatedTask[];
  onRevealCard?: ((card: ChatAttentionCard) => void) | undefined;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const popoverId = useId();
  const popoverRef = useRef<HTMLElement>(null);
  const attentionTriggerRef = useRef<HTMLButtonElement>(null);
  const activeTriggerRef = useRef<HTMLButtonElement>(null);
  const [openPopover, setOpenPopover] = useState<ChatDockPopoverKind | null>(
    defaultOpenPopover
  );
  const [activeFilter, setActiveFilter] = useState<ActiveTaskFilter>("all");
  const attentionScrollOffsetRef = useRef(0);
  const activeScrollOffsetRef = useRef(0);

  const attentionTasks = useMemo(
    () => items.filter((task) => !isActiveTask(task)),
    [items]
  );
  const activeTasks = useMemo(
    () => items.filter((task) => isActiveTask(task)),
    [items]
  );

  // Tasks this panel has already shown. A row outside it is arriving; a row
  // mounting because the popover opened or scrolled into view does not replay
  // arrival motion.
  const dockedTaskIdsRef = useRef<ReadonlySet<string> | null>(null);
  useEffect(() => {
    dockedTaskIdsRef.current = new Set(items.map((task) => task.conversationId));
  }, [items]);

  const attentionCount = attentionCards.length + attentionTasks.length;
  const activeCount = activeTasks.length;

  const effectivePopover: ChatDockPopoverKind | null =
    openPopover === "attention" && attentionCount > 1
      ? "attention"
      : openPopover === "active" && activeCount > 0
        ? "active"
        : null;

  useEffect(() => {
    if (openPopover !== null && effectivePopover === null) {
      setOpenPopover(null);
    }
  }, [effectivePopover, openPopover]);

  // Close the floating popover on Escape or clicking outside (ignoring the
  // popover itself, its toggle buttons, and portaled menus such as
  // TaskArchiveMenu so selecting Archive never unmounts the row).
  useEffect(() => {
    if (effectivePopover === null) return undefined;
    // Captured and consumed: an open reply thread also leaves on Escape from
    // window, and one Escape closes only the popover above it.
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape" && !event.defaultPrevented) {
        event.preventDefault();
        event.stopImmediatePropagation();
        setOpenPopover(null);
      }
    };
    const handlePointerDown = (event: PointerEvent) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (
        popoverRef.current?.contains(target) ||
        attentionTriggerRef.current?.contains(target) ||
        activeTriggerRef.current?.contains(target)
      ) {
        return;
      }
      if (target instanceof Element && target.closest('[data-slot="menu-popover"]')) {
        return;
      }
      setOpenPopover(null);
    };
    window.addEventListener("keydown", handleKeyDown, true);
    document.addEventListener("pointerdown", handlePointerDown, true);
    return () => {
      window.removeEventListener("keydown", handleKeyDown, true);
      document.removeEventListener("pointerdown", handlePointerDown, true);
    };
  }, [effectivePopover]);

  // Top-priority focus item for the left bubble: pending confirmation cards
  // first, then escalated (needsInput), unseen needs_review, and other settled.
  const focusCard = attentionCards[0];
  const focusTask = useMemo(() => {
    if (focusCard || attentionTasks.length === 0) return undefined;
    return (
      attentionTasks.find((task) => task.needsInput) ??
      attentionTasks.find((task) => task.needsAttention) ??
      attentionTasks[0]
    );
  }, [attentionTasks, focusCard]);

  const inProgressCount = useMemo(
    () => activeTasks.filter((task) => task.statusBucket === "in_progress").length,
    [activeTasks]
  );
  const loopsCount = activeCount - inProgressCount;
  const filteredActiveTasks = useMemo(() => {
    if (activeFilter === "all" || inProgressCount === 0 || loopsCount === 0) {
      return activeTasks;
    }
    return activeTasks.filter((task) => task.statusBucket === activeFilter);
  }, [activeFilter, activeTasks, inProgressCount, loopsCount]);

  const hasLiveRunning = useMemo(
    () =>
      activeTasks.some((task) => task.statusBucket === "in_progress" && !task.loopStop),
    [activeTasks]
  );

  const handleRevealCard = useCallback(
    (card: ChatAttentionCard) => {
      onRevealCard?.(card);
      setOpenPopover(null);
    },
    [onRevealCard]
  );

  const handleRevealTask = useCallback(
    (task: ChatCreatedTask) => {
      onReveal(task);
      setOpenPopover(null);
    },
    [onReveal]
  );

  if (attentionCount === 0 && activeCount === 0) return null;

  const restAttentionCount = Math.max(0, attentionCount - 1);
  const formattedAttentionCount = formatNumber(attentionCount, locale);
  const formattedActiveCount = formatNumber(activeCount, locale);
  const activeOnlyLoops = inProgressCount === 0 && loopsCount > 0;
  const activePillLabel = activeOnlyLoops
    ? messages.chat_dock_active_loops_count({
        count: activeCount,
        formattedCount: formattedActiveCount,
      })
    : messages.chat_dock_active_count({
        count: activeCount,
        formattedCount: formattedActiveCount,
      });

  const activePillIcon = hasLiveRunning ? (
    <LoaderIcon
      aria-hidden
      className="comma-task-status-spin text-sidebar-icon-secondary"
    />
  ) : activeTasks[0] ? (
    taskStatusIcon(activeTasks[0].statusBucket, {
      loopStanding: activeTasks[0].loopStanding,
      loopStop: activeTasks[0].loopStop,
      spins: false,
    })
  ) : (
    <LoaderIcon aria-hidden className="text-sidebar-icon-secondary" />
  );

  return (
    <div
      aria-label={messages.chat_task_panel_label()}
      aria-orientation="horizontal"
      className="comma-chat-task-panel"
      data-popover={effectivePopover ?? undefined}
      data-testid="chat-task-panel"
      role="toolbar"
    >
      {effectivePopover === "attention" ? (
        <section
          aria-label={messages.chat_dock_attention_title({
            formattedCount: formattedAttentionCount,
          })}
          className="comma-chat-dock-popover"
          data-testid="chat-dock-attention-popover"
          id={popoverId}
          ref={popoverRef}
        >
          <div className="comma-chat-dock-popover-head">
            <div className="comma-chat-dock-popover-title">
              <BubbleAlertIcon
                aria-hidden
                className="comma-chat-dock-head-alert-icon"
              />
              <span>
                {messages.chat_dock_attention_title({
                  formattedCount: formattedAttentionCount,
                })}
              </span>
            </div>
            <AriaButton
              aria-label={messages.chat_dock_close()}
              className="comma-chat-dock-popover-close"
              data-no-press-feedback
              onPress={() => setOpenPopover(null)}
            >
              <XIcon aria-hidden />
            </AriaButton>
          </div>
          {attentionCards.length > 0 ? (
            <div className="comma-chat-dock-section">
              <div className="comma-chat-dock-section-label">
                <span>{messages.chat_dock_section_cards()}</span>
                <span className="comma-chat-dock-tabular">
                  {formatNumber(attentionCards.length, locale)}
                </span>
              </div>
              <ul
                className="comma-chat-dock-card-list"
                data-testid="chat-dock-attention-cards"
              >
                {attentionCards.map((card) => (
                  <li key={card.id}>
                    <ChatAttentionCardRow card={card} onReveal={handleRevealCard} />
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
          {attentionTasks.length > 0 ? (
            <div className="comma-chat-dock-section">
              {attentionCards.length > 0 ? (
                <div className="comma-chat-dock-section-label">
                  <span>{messages.chat_dock_section_tasks()}</span>
                  <span className="comma-chat-dock-tabular">
                    {formatNumber(attentionTasks.length, locale)}
                  </span>
                </div>
              ) : null}
              <ChatTaskList
                arrival="expand"
                dockedTaskIdsRef={dockedTaskIdsRef}
                id={`${popoverId}-tasks`}
                items={attentionTasks}
                onArchive={onArchive}
                onDismiss={onDismiss}
                onOpen={onOpen}
                onReveal={handleRevealTask}
                scrollOffsetRef={attentionScrollOffsetRef}
              />
            </div>
          ) : null}
        </section>
      ) : null}

      {effectivePopover === "active" ? (
        <section
          aria-label={messages.chat_dock_active_title({
            formattedCount: formattedActiveCount,
          })}
          className="comma-chat-dock-popover"
          data-testid="chat-dock-active-popover"
          id={popoverId}
          ref={popoverRef}
        >
          <div className="comma-chat-dock-popover-head">
            <div className="comma-chat-dock-popover-title">
              <span>
                {messages.chat_dock_active_title({
                  formattedCount: formattedActiveCount,
                })}
              </span>
            </div>
            <div className="comma-chat-dock-popover-head-right">
              {inProgressCount > 0 && loopsCount > 0 ? (
                <div className="comma-chat-dock-filter-group">
                  {(
                    [
                      [
                        "all",
                        messages.chat_dock_filter_all({
                          formattedCount: formattedActiveCount,
                        }),
                      ],
                      [
                        "in_progress",
                        messages.chat_dock_filter_in_progress({
                          formattedCount: formatNumber(inProgressCount, locale),
                        }),
                      ],
                      [
                        "loops",
                        messages.chat_dock_filter_loops({
                          formattedCount: formatNumber(loopsCount, locale),
                        }),
                      ],
                    ] as const
                  ).map(([filterKey, label]) => (
                    <AriaButton
                      aria-pressed={activeFilter === filterKey}
                      className="comma-chat-dock-filter-btn"
                      data-active={activeFilter === filterKey ? "true" : undefined}
                      data-no-press-feedback
                      key={filterKey}
                      onPress={() => setActiveFilter(filterKey)}
                    >
                      {label}
                    </AriaButton>
                  ))}
                </div>
              ) : null}
              <AriaButton
                aria-label={messages.chat_dock_close()}
                className="comma-chat-dock-popover-close"
                data-no-press-feedback
                onPress={() => setOpenPopover(null)}
              >
                <XIcon aria-hidden />
              </AriaButton>
            </div>
          </div>
          <ChatTaskList
            arrival="expand"
            dockedTaskIdsRef={dockedTaskIdsRef}
            id={`${popoverId}-active`}
            items={filteredActiveTasks}
            onArchive={onArchive}
            onDismiss={onDismiss}
            onOpen={onOpen}
            onReveal={handleRevealTask}
            scrollOffsetRef={activeScrollOffsetRef}
          />
        </section>
      ) : null}

      <div className="comma-chat-dock-bar">
        {focusCard ? (
          <div className="comma-chat-dock-focus-wrap">
            <div
              className="comma-chat-dock-focus"
              data-testid="chat-dock-attention-focus"
            >
              <AriaButton
                className="comma-chat-dock-focus-main"
                data-no-press-feedback
                data-testid={`chat-dock-card-${focusCard.id}`}
                onPress={() => handleRevealCard(focusCard)}
              >
                <span aria-hidden className="comma-chat-dock-focus-glyph">
                  {cardKindIcon(focusCard.kind)}
                </span>
                <span className="comma-chat-dock-focus-title">{focusCard.title}</span>
                <span className="comma-chat-dock-kicker">{focusCard.kindLabel}</span>
              </AriaButton>
              <div className="comma-chat-dock-focus-actions">
                {focusCard.expiresAt !== null ? (
                  <DockCountdown expiresAt={focusCard.expiresAt} />
                ) : null}
                {/* The whole bubble is the button; this only names its action. */}
                <span aria-hidden className="comma-chat-dock-cta">
                  {focusCard.actionLabel}
                </span>
                {restAttentionCount > 0 ? (
                  <AriaButton
                    {...(effectivePopover === "attention"
                      ? { "aria-controls": popoverId }
                      : {})}
                    aria-expanded={effectivePopover === "attention"}
                    aria-label={messages.chat_dock_attention_more_aria({
                      formattedCount: formattedAttentionCount,
                    })}
                    className="comma-chat-dock-more-btn"
                    data-no-press-feedback
                    data-testid="chat-dock-attention-toggle"
                    onPress={() =>
                      setOpenPopover((current) =>
                        current === "attention" ? null : "attention"
                      )
                    }
                    ref={attentionTriggerRef}
                  >
                    <span className="comma-chat-dock-tabular">
                      +{formatNumber(restAttentionCount, locale)}
                    </span>
                    <ChevronTopSmallIcon
                      aria-hidden
                      className="comma-chat-dock-chevron"
                    />
                  </AriaButton>
                ) : null}
              </div>
            </div>
          </div>
        ) : focusTask ? (
          <FocusTaskBubble
            arriving={!dockedTaskIdsRef.current?.has(focusTask.conversationId)}
            expanded={effectivePopover === "attention"}
            onArchive={onArchive}
            onDismiss={onDismiss}
            onOpen={onOpen}
            onReveal={onReveal}
            onTogglePopover={() =>
              setOpenPopover((current) =>
                current === "attention" ? null : "attention"
              )
            }
            popoverId={popoverId}
            restCount={restAttentionCount}
            task={focusTask}
            toggleRef={attentionTriggerRef}
            totalAttentionCount={attentionCount}
          />
        ) : null}

        {activeCount > 0 ? (
          <AriaButton
            {...(effectivePopover === "active" ? { "aria-controls": popoverId } : {})}
            aria-expanded={effectivePopover === "active"}
            className="comma-chat-dock-active-pill"
            data-no-press-feedback
            data-testid="chat-task-panel-toggle"
            onPress={() =>
              setOpenPopover((current) => (current === "active" ? null : "active"))
            }
            ref={activeTriggerRef}
          >
            <span aria-hidden className="comma-chat-dock-pill-icon">
              {activePillIcon}
            </span>
            <span className="comma-chat-dock-tabular">{activePillLabel}</span>
            <ChevronTopSmallIcon aria-hidden className="comma-chat-dock-chevron" />
          </AriaButton>
        ) : null}
      </div>
    </div>
  );
});

const FocusTaskBubble = memo(function FocusTaskBubble({
  arriving,
  expanded,
  onArchive,
  onDismiss,
  onOpen,
  onReveal,
  onTogglePopover,
  popoverId,
  restCount,
  task,
  toggleRef,
  totalAttentionCount,
}: ChatTaskActions & {
  arriving: boolean;
  expanded: boolean;
  onTogglePopover: () => void;
  popoverId: string;
  restCount: number;
  task: ChatCreatedTask;
  toggleRef: RefObject<HTMLButtonElement | null>;
  totalAttentionCount: number;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const [arrival, setArrival] = useState(arriving);
  const focusRef = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const item = focusRef.current;
    if (!item || !arrival) return undefined;
    const clearArrival = (event: AnimationEvent) => {
      if (
        event.target === item &&
        event.animationName === "comma-chat-task-item-reveal"
      ) {
        setArrival(false);
      }
    };
    item.addEventListener("animationend", clearArrival);
    item.addEventListener("animationcancel", clearArrival);
    return () => {
      item.removeEventListener("animationend", clearArrival);
      item.removeEventListener("animationcancel", clearArrival);
    };
  }, [arrival]);
  const title = task.title || messages.chat_ref_task();
  const isSingle = restCount === 0;
  const canReveal = task.turnKey !== undefined;
  const archiveAction = useMemo<TaskArchiveAction | undefined>(
    () =>
      isSingle && task.archiveVersion !== undefined
        ? { run: () => onArchive(task) }
        : undefined,
    [isSingle, onArchive, task]
  );

  return (
    <div className="comma-chat-dock-focus-wrap">
      <TaskArchiveMenu action={archiveAction}>
        {(archiveTrigger) => (
          <div
            className="comma-chat-dock-focus"
            data-arriving={arrival ? "true" : undefined}
            data-single-task={isSingle ? "true" : undefined}
            data-status={task.statusBucket}
            data-testid={
              isSingle
                ? `chat-task-item-${task.conversationId}`
                : "chat-dock-attention-focus"
            }
            ref={focusRef}
          >
            <AriaButton
              aria-label={messages.tasks_open({ title })}
              className="comma-chat-dock-focus-main"
              data-no-press-feedback
              onPress={(event) =>
                onOpen(task, event.metaKey || event.ctrlKey ? "page" : "chat")
              }
            >
              <span aria-hidden className="comma-chat-dock-focus-glyph">
                {taskStatusIcon(task.statusBucket, {
                  loopStanding: task.loopStanding,
                  loopStop: task.loopStop,
                })}
              </span>
              <TitleSwap
                className="comma-chat-dock-focus-title"
                identity={task.title ? task.conversationId : undefined}
                text={title}
              />
            </AriaButton>
            {isSingle ? (
              <div className="comma-chat-dock-single-actions">
                <AriaButton
                  aria-label={messages.chat_task_dismiss_aria({ title })}
                  className="comma-chat-task-item-action comma-chat-task-item-dismiss"
                  data-testid={`chat-task-dismiss-${task.conversationId}`}
                  onPress={() => onDismiss(task)}
                >
                  {messages.chat_task_dismiss()}
                </AriaButton>
                {canReveal ? (
                  <AriaButton
                    aria-label={messages.chat_task_reveal_aria({ title })}
                    className="comma-chat-task-item-action comma-chat-task-item-reveal"
                    data-testid={`chat-task-reveal-${task.conversationId}`}
                    onPress={() => onReveal(task)}
                  >
                    {messages.chat_task_reveal()}
                  </AriaButton>
                ) : null}
                {archiveTrigger}
              </div>
            ) : (
              <div className="comma-chat-dock-focus-actions">
                <AriaButton
                  {...(expanded ? { "aria-controls": popoverId } : {})}
                  aria-expanded={expanded}
                  aria-label={messages.chat_dock_attention_more_aria({
                    formattedCount: formatNumber(totalAttentionCount, locale),
                  })}
                  className="comma-chat-dock-more-btn"
                  data-no-press-feedback
                  data-testid="chat-dock-attention-toggle"
                  onPress={onTogglePopover}
                  ref={toggleRef}
                >
                  <span className="comma-chat-dock-tabular">
                    +{formatNumber(restCount, locale)}
                  </span>
                  <ChevronTopSmallIcon
                    aria-hidden
                    className="comma-chat-dock-chevron"
                  />
                </AriaButton>
              </div>
            )}
          </div>
        )}
      </TaskArchiveMenu>
    </div>
  );
});

const ChatAttentionCardRow = memo(function ChatAttentionCardRow({
  card,
  onReveal,
}: {
  card: ChatAttentionCard;
  onReveal: (card: ChatAttentionCard) => void;
}) {
  return (
    <AriaButton
      className="comma-chat-dock-card-row"
      data-no-press-feedback
      data-testid={`chat-dock-card-row-${card.id}`}
      onPress={() => onReveal(card)}
    >
      <span aria-hidden className="comma-chat-task-item-icon">
        {cardKindIcon(card.kind)}
      </span>
      <span aria-hidden className="comma-chat-dock-dot" />
      <span className="comma-chat-task-item-title">{card.title}</span>
      <span className="comma-chat-dock-kicker">{card.kindLabel}</span>
      {card.expiresAt !== null ? (
        <span className="comma-chat-dock-card-trailing">
          <DockCountdown expiresAt={card.expiresAt} />
        </span>
      ) : null}
    </AriaButton>
  );
});

function ChatTaskList({
  arrival,
  dockedTaskIdsRef,
  id,
  items,
  onArchive,
  onDismiss,
  onOpen,
  onReveal,
  scrollOffsetRef,
}: ChatTaskActions & {
  arrival: "dock" | "expand";
  dockedTaskIdsRef: RefObject<ReadonlySet<string> | null>;
  id: string;
  items: readonly ChatCreatedTask[];
  /** Survives the list: folding the popover must not lose the reader's place. */
  scrollOffsetRef: RefObject<number>;
}) {
  const scrollRef = useRef<HTMLDivElement>(null);
  const probeRef = useRef<HTMLDivElement>(null);
  const [geometry, setGeometry] = useState(DEFAULT_ROW_GEOMETRY);
  const [focusedTaskId, setFocusedTaskId] = useState<string | null>(null);

  // Row height and gap are design tokens (the height follows the font-size
  // preference), while a window over the list needs them in pixels. The probe
  // wears both tokens, so they are read from one box and never restated here.
  useLayoutEffect(() => {
    const probe = probeRef.current;
    if (!probe) return undefined;
    const measure = () => {
      const { height, width } = probe.getBoundingClientRect();
      if (height <= 0) return undefined;
      return (current: RowGeometry) =>
        current.block === height && current.gap === width
          ? current
          : { block: height, gap: width };
    };
    // The first read waits for the frame's shared read phase: in the commit
    // it would lay the mounting page out again. Its write renders there, so
    // the panel first paints at the probe's size, not the default's, and the
    // observer's first report then finds nothing changed.
    const cancelFirstRead = scheduleLayoutRead(() => {
      const next = measure();
      return next && (() => flushSync(() => setGeometry(next)));
    });
    const observer = new ResizeObserver(() => {
      const next = measure();
      if (next) setGeometry(next);
    });
    observer.observe(probe);
    return () => {
      cancelFirstRead();
      observer.disconnect();
    };
  }, []);

  // The scroller is sized by the same tokens, so its height is known without
  // observing it: the rows on screen, their gaps, and the leading inset.
  const viewportBlock =
    Math.min(items.length, VISIBLE_ROWS) * (geometry.block + geometry.gap);
  const rectListenerRef = useRef<((rect: Rect) => void) | undefined>(undefined);
  const focusedIndex = useMemo(
    () =>
      focusedTaskId === null
        ? -1
        : items.findIndex((task) => task.conversationId === focusedTaskId),
    [focusedTaskId, items]
  );
  const virtualizer = useVirtualizer({
    count: items.length,
    estimateSize: () => geometry.block,
    gap: geometry.gap,
    getItemKey: useCallback((index: number) => items[index]!.conversationId, [items]),
    getScrollElement: () => scrollRef.current,
    initialOffset: () => scrollOffsetRef.current,
    initialRect: { height: viewportBlock, width: 0 },
    observeElementRect: useCallback(
      (_instance: unknown, callback: (rect: Rect) => void) => {
        rectListenerRef.current = callback;
        return () => {
          rectListenerRef.current = undefined;
        };
      },
      []
    ),
    overscan: 2,
    // The inset above the first row is the gap under the header.
    paddingStart: geometry.gap,
    // A focused row stays mounted with its neighbours, so keyboard focus
    // survives scrolling and Tab always has a next row to land on.
    rangeExtractor: useCallback(
      (range: Range) => {
        const indexes = defaultRangeExtractor(range);
        if (focusedIndex < 0) return indexes;
        for (
          let index = Math.max(0, focusedIndex - 1);
          index <= Math.min(range.count - 1, focusedIndex + 1);
          index++
        ) {
          indexes.push(index);
        }
        return [...new Set(indexes)].toSorted((a, b) => a - b);
      },
      [focusedIndex]
    ),
  });
  useLayoutEffect(() => {
    rectListenerRef.current?.({ height: viewportBlock, width: 0 });
  }, [viewportBlock]);
  // Cached row sizes only go stale when the tokens resolve to new pixels.
  const measuredGeometryRef = useRef(geometry);
  useLayoutEffect(() => {
    if (measuredGeometryRef.current === geometry) return;
    measuredGeometryRef.current = geometry;
    virtualizer.measure();
  }, [geometry, virtualizer]);

  const dockedTaskIds = dockedTaskIdsRef.current;
  let arrivalOrder = 0;
  return (
    <div
      className="comma-chat-task-panel-list"
      data-arrival={arrival}
      data-testid="chat-task-panel-list"
      id={id}
      onBlurCapture={(event) => {
        if (!event.currentTarget.contains(event.relatedTarget as Node | null)) {
          setFocusedTaskId(null);
        }
      }}
      onFocusCapture={(event) => {
        setFocusedTaskId(
          (event.target as HTMLElement).closest<HTMLElement>("[data-chat-task-id]")
            ?.dataset["chatTaskId"] ?? null
        );
      }}
      onScroll={(event) => {
        scrollOffsetRef.current = event.currentTarget.scrollTop;
      }}
      ref={scrollRef}
    >
      <div aria-hidden className="comma-chat-task-panel-probe" ref={probeRef} />
      <ul
        className="comma-chat-task-panel-rows"
        style={{ blockSize: virtualizer.getTotalSize() }}
      >
        {virtualizer.getVirtualItems().map((virtual) => {
          const task = items[virtual.index]!;
          const arriving = !dockedTaskIds?.has(task.conversationId);
          return (
            <li
              aria-posinset={virtual.index + 1}
              aria-setsize={items.length}
              className="comma-chat-task-panel-row"
              data-chat-task-id={task.conversationId}
              key={virtual.key}
              style={{ transform: `translateY(${virtual.start}px)` }}
            >
              <ChatTaskRow
                arrivalOrder={arriving ? arrivalOrder++ : undefined}
                onArchive={onArchive}
                onDismiss={onDismiss}
                onOpen={onOpen}
                onReveal={onReveal}
                task={task}
              />
            </li>
          );
        })}
      </ul>
    </div>
  );
}

const ChatTaskRow = memo(function ChatTaskRow({
  arrivalOrder,
  onArchive,
  onDismiss,
  onOpen,
  onReveal,
  task,
}: ChatTaskActions & {
  /** Place among the rows arriving together; undefined when not arriving. */
  arrivalOrder: number | undefined;
  task: ChatCreatedTask;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  // Arrival is decided once, when the row mounts: later renders of a row that
  // is still playing its arrival must not cut the motion short.
  const [arrival, setArrival] = useState(arrivalOrder);
  const itemRef = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const item = itemRef.current;
    if (!item || arrival === undefined) return undefined;
    const clearArrival = (event: AnimationEvent) => {
      if (
        event.target === item &&
        event.animationName === "comma-chat-task-item-reveal"
      ) {
        setArrival(undefined);
      }
    };
    // A zero-duration reduced-motion animation still completes through the
    // same event path. Cancellation also settles the one-shot marker.
    item.addEventListener("animationend", clearArrival);
    item.addEventListener("animationcancel", clearArrival);
    return () => {
      item.removeEventListener("animationend", clearArrival);
      item.removeEventListener("animationcancel", clearArrival);
    };
  }, [arrival]);
  const title = task.title || messages.chat_ref_task();
  const settled = !isActiveTask(task);
  const canReveal = task.turnKey !== undefined;
  const archiveAction = useMemo<TaskArchiveAction | undefined>(
    () =>
      task.archiveVersion === undefined ? undefined : { run: () => onArchive(task) },
    [onArchive, task]
  );

  return (
    <TaskArchiveMenu action={archiveAction}>
      {(archiveTrigger) => (
        <div
          className="comma-chat-task-item"
          data-arriving={arrival === undefined ? undefined : "true"}
          data-status={task.statusBucket}
          data-testid={`chat-task-item-${task.conversationId}`}
          ref={itemRef}
          style={
            arrival === undefined
              ? undefined
              : ({ "--comma-chat-task-arrival": arrival } as CSSProperties)
          }
        >
          {/* Opening the Task is the row's own answer to a press, so the shared
              button press scale would only add a shrink under that. */}
          <AriaButton
            aria-label={messages.tasks_open({ title })}
            className="comma-chat-task-item-row"
            data-no-press-feedback
            onPress={(event) =>
              onOpen(task, event.metaKey || event.ctrlKey ? "page" : "chat")
            }
          >
            <span aria-hidden className="comma-chat-task-item-icon">
              {taskStatusIcon(task.statusBucket, {
                loopStanding: task.loopStanding,
                loopStop: task.loopStop,
              })}
            </span>
            <span
              aria-hidden
              className="comma-chat-task-item-dot"
              data-state={task.needsAttention ? "visible" : "hidden"}
            >
              <span className="comma-chat-task-item-dot-inner" />
            </span>
            <TitleSwap
              className="comma-chat-task-item-title"
              // The placeholder giving way to the first title is no rename.
              identity={task.title ? task.conversationId : undefined}
              text={title}
            />
            <span
              className={
                settled || task.loopStop || task.loopStanding
                  ? "comma-chat-task-item-status"
                  : "comma-chat-task-item-status comma-shiny-text"
              }
              title={
                !task.needsInput && !task.loopStop
                  ? task.loopStanding?.title
                  : undefined
              }
            >
              {task.needsInput
                ? taskStatusLabel("escalated", locale)
                : (task.loopStop?.text ??
                  task.loopStanding?.text ??
                  taskStatusBucketLabel(task.statusBucket, locale))}
            </span>
          </AriaButton>
          {/* A Task announced before any user turn has no turn to jump to. */}
          {(settled || canReveal || archiveTrigger) && (
            <div className="comma-chat-task-item-actions">
              {settled && (
                <AriaButton
                  aria-label={messages.chat_task_dismiss_aria({ title })}
                  className="comma-chat-task-item-action comma-chat-task-item-dismiss"
                  data-testid={`chat-task-dismiss-${task.conversationId}`}
                  onPress={() => onDismiss(task)}
                >
                  {messages.chat_task_dismiss()}
                </AriaButton>
              )}
              {canReveal && (
                <AriaButton
                  aria-label={messages.chat_task_reveal_aria({ title })}
                  className="comma-chat-task-item-action comma-chat-task-item-reveal"
                  data-testid={`chat-task-reveal-${task.conversationId}`}
                  onPress={() => onReveal(task)}
                >
                  {messages.chat_task_reveal()}
                </AriaButton>
              )}
              {archiveTrigger}
            </div>
          )}
        </div>
      )}
    </TaskArchiveMenu>
  );
});
