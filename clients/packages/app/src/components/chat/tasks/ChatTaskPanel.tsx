import { formatNumber, taskStatusBucketLabel, taskStatusLabel } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { ChevronDownSmallIcon } from "@comma/ui/components/icons";
import { TitleSwap } from "@comma/ui/components/title-swap";
import {
  TaskArchiveMenu,
  type TaskArchiveAction,
} from "@comma/ui/components/task-workspace/TaskArchiveMenu";
import { taskStatusIcon } from "@comma/ui/components/task-workspace";
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
import { flushSync } from "react-dom";
import { Button as AriaButton } from "react-aria-components";
import { scheduleLayoutRead } from "@comma/ui/clock";
import {
  setChatTaskPanelCollapsed,
  useChatTaskPanelCollapsed,
} from "./chatTaskPanelCollapse";
import type { ChatCreatedTask } from "./useChatCreatedTasks";

/** "chat" opens the Task's chat beside this one; "page" opens the Task itself. */
export type ChatTaskOpenTarget = "chat" | "page";

type ChatTaskActions = {
  onArchive: (task: ChatCreatedTask) => Promise<void>;
  onDismiss: (task: ChatCreatedTask) => void;
  onOpen: (task: ChatCreatedTask, target: ChatTaskOpenTarget) => void;
  onReveal: (task: ChatCreatedTask) => void;
};

/** Rows on screen at once; past this the list scrolls inside the panel. */
const VISIBLE_ROWS = 5;

type RowGeometry = { block: number; gap: number };

/** Token geometry at the default font size, until the probe has been read. */
const DEFAULT_ROW_GEOMETRY: RowGeometry = { block: 28, gap: 2 };

/**
 * The Tasks the agent created in this conversation, pinned above the composer
 * in creation order. A row is the Task: pressing it opens the Task's chat, the
 * same way the Task's chip in the transcript does. Hover reveals a trailing
 * cluster laid over the row rather than reserving it: "Reveal in Chat" jumps
 * to the turn that announced the Task, a settled row also offers "Dismiss",
 * and More opens Archive when that is available. The cluster stays up while
 * the pointer is on any of those controls; clicking More must not open,
 * reveal, or dismiss the row.
 *
 * A header names the count and doubles as the disclosure. Collapsed, the list
 * is not rendered at all, so the panel is its one header line and nothing
 * behind it keeps animating, updating, or taking focus. The fold is the
 * reader's choice for every conversation and outlives the app
 * (chatTaskPanelCollapse.ts), so a panel folded away stays folded.
 *
 * Five rows show at a time and only those rows (plus a short overscan) are
 * mounted: a long-lived conversation docks every Task it ever announced, and
 * the panel's cost must follow what is on screen, not that history.
 */
export const ChatTaskPanel = memo(function ChatTaskPanel({
  items,
  onArchive,
  onDismiss,
  onOpen,
  onReveal,
}: ChatTaskActions & { items: readonly ChatCreatedTask[] }) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const listId = useId();
  const collapsed = useChatTaskPanelCollapsed();
  // Expanding is the reader asking for the list back, not Tasks arriving: the
  // list fades in as one piece instead of replaying each row's arrival.
  const [listArrival, setListArrival] = useState<"dock" | "expand">("dock");
  const scrollOffsetRef = useRef(0);
  // Tasks this panel has already shown. A row outside it is arriving; a row
  // mounting for any other reason (scrolled into the window, list expanded)
  // is not, and must not replay the arrival motion.
  const dockedTaskIdsRef = useRef<ReadonlySet<string> | null>(null);
  useEffect(() => {
    dockedTaskIdsRef.current = new Set(items.map((task) => task.conversationId));
  }, [items]);

  if (items.length === 0) return null;

  return (
    <div
      aria-label={messages.chat_task_panel_label()}
      aria-orientation="vertical"
      className="comma-chat-task-panel"
      data-collapsed={collapsed ? "true" : undefined}
      data-testid="chat-task-panel"
      role="toolbar"
    >
      {/* The header is the whole press target, not just the chevron: a 20px
          icon is a small thing to hit for a state the user toggles casually. */}
      <AriaButton
        {...(collapsed ? {} : { "aria-controls": listId })}
        aria-expanded={!collapsed}
        className="comma-chat-task-panel-toggle"
        data-no-press-feedback
        data-testid="chat-task-panel-toggle"
        onPress={() => {
          setListArrival("expand");
          setChatTaskPanelCollapsed(!collapsed);
        }}
      >
        <span className="comma-chat-task-panel-count">
          {messages.chat_task_panel_count({
            count: items.length,
            formattedCount: formatNumber(items.length, locale),
          })}
        </span>
        <ChevronDownSmallIcon aria-hidden className="comma-chat-task-panel-chevron" />
      </AriaButton>
      {collapsed ? null : (
        <ChatTaskList
          arrival={listArrival}
          dockedTaskIdsRef={dockedTaskIdsRef}
          id={listId}
          items={items}
          onArchive={onArchive}
          onDismiss={onDismiss}
          onOpen={onOpen}
          onReveal={onReveal}
          scrollOffsetRef={scrollOffsetRef}
        />
      )}
    </div>
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
  /** Survives the list: folding the panel must not lose the reader's place. */
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
  const settled = task.statusBucket !== "in_progress";
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
              {taskStatusIcon(task.statusBucket)}
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
                settled
                  ? "comma-chat-task-item-status"
                  : "comma-chat-task-item-status comma-shiny-text"
              }
            >
              {task.needsInput
                ? taskStatusLabel("escalated", locale)
                : taskStatusBucketLabel(task.statusBucket, locale)}
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
