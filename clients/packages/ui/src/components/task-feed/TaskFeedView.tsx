import { formatNumber } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { Button as AriaButton, type Selection } from "react-aria-components";
import { spacing } from "../../tokens";
import { Button } from "../Button";
import {
  ArrowLeftIcon,
  ArrowUpIcon,
  ColumnWideAddIcon,
  ExpandSimpleIcon,
  MoreHorizontalIcon,
} from "../icons";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "../menu";
import { ScrollArea, ScrollAreaLoadMore } from "../scroll-area";
import { taskCardSurface } from "../task-board/styles";
import { taskStatusIcon } from "../task-workspace/TaskSummaryCard";
import { cx } from "../utils";
import { normalizeEpochMs } from "./feedTime";
import { TaskFeedEntryRow } from "./TaskFeedEntryRow";
import type {
  TaskFeedColumnId,
  TaskFeedEntry,
  TaskFeedSessionInspectorContext,
  TaskFeedViewProps,
} from "./types";

const ALL_COLUMNS: readonly TaskFeedColumnId[] = [
  "needs_review",
  "in_progress",
  "done",
  "cancelled",
];

const DEFAULT_VISIBLE_COLUMNS: readonly TaskFeedColumnId[] = [
  "needs_review",
  "in_progress",
  "done",
];

interface ColumnDrillState {
  entryId: string;
  revealMessageId?: string | undefined;
}

function isEditableElement(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  if (target.isContentEditable) return true;
  const tag = target.tagName;
  return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
}

function columnLabel(
  column: TaskFeedColumnId,
  messages: ReturnType<typeof useCommaMessages>
): string {
  switch (column) {
    case "needs_review":
      return messages.task_feed_column_needs_review();
    case "in_progress":
      return messages.task_feed_column_in_progress();
    case "done":
      return messages.task_feed_column_done();
    case "cancelled":
      return messages.task_feed_column_cancelled();
  }
}

function columnEmptyLabel(
  column: TaskFeedColumnId,
  messages: ReturnType<typeof useCommaMessages>
): string {
  switch (column) {
    case "needs_review":
      return messages.task_feed_column_empty_needs_review();
    case "in_progress":
      return messages.task_feed_column_empty_in_progress();
    case "done":
      return messages.task_feed_column_empty_done();
    case "cancelled":
      return messages.task_feed_column_empty_cancelled();
  }
}

/** Columns share the deck's width and scroll sideways once they reach their minimum. */
const DECK_COLUMN_WIDTH_CLASS = "max-w-140 min-w-90 flex-1 shrink-0 basis-0";

/**
 * The deck's own minimum: every column at `min-w-90`, the size-7 manage-columns
 * button when shown, the `gap-xl` gaps and the `px-2xl` padding. The deck fills
 * the viewport until it reaches this, then scrolls sideways.
 */
function deckMinWidth(columns: number, manageButton: boolean): string {
  const items = columns + (manageButton ? 1 : 0);
  const button = manageButton ? " + var(--spacing) * 7" : "";
  return `calc(${columns} * var(--spacing) * 90${button} + ${Math.max(0, items - 1)} * var(--spacing-xl) + 2 * var(--spacing-2xl))`;
}

const HEADER_ICON_BUTTON_CLASS =
  "inline-flex size-7 shrink-0 cursor-pointer items-center justify-center rounded-full bg-transparent text-tertiary outline-none transition-colors hover:bg-secondary-hover hover:text-primary focus-visible:shadow-focus-gray aria-expanded:bg-secondary-hover aria-expanded:text-primary";

function ManageColumnsMenu({
  counts,
  onChange,
  visibleColumns,
}: {
  counts: Readonly<Record<TaskFeedColumnId, number>>;
  onChange: (columns: TaskFeedColumnId[]) => void;
  visibleColumns: readonly TaskFeedColumnId[];
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const handleSelectionChange = (keys: Selection) => {
    const next =
      keys === "all" ? [...ALL_COLUMNS] : ALL_COLUMNS.filter((col) => keys.has(col));
    if (next.length > 0) onChange(next);
  };

  return (
    <MenuTrigger>
      <AriaButton
        aria-label={messages.task_feed_column_add()}
        className={HEADER_ICON_BUTTON_CLASS}
        data-slot="task-feed-add-column"
      >
        <ColumnWideAddIcon aria-hidden className="size-4" />
      </AriaButton>
      <MenuPopover offset={spacing.xs} placement="bottom end">
        <Menu
          aria-label={messages.task_feed_column_add()}
          disallowEmptySelection
          onSelectionChange={handleSelectionChange}
          selectedKeys={visibleColumns}
          selectionMode="multiple"
        >
          {ALL_COLUMNS.map((col) => (
            <MenuItem
              data-column-toggle={col}
              icon={taskStatusIcon(col, { spins: false })}
              id={col}
              key={col}
              note={formatNumber(counts[col], locale)}
              selectionIndicator="check"
              textValue={columnLabel(col, messages)}
            >
              {columnLabel(col, messages)}
            </MenuItem>
          ))}
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}

function ColumnOptionsMenu({
  column,
  onHide,
  onMarkCaughtUp,
}: {
  column: TaskFeedColumnId;
  onHide?: (() => void) | undefined;
  onMarkCaughtUp?: (() => void) | undefined;
}) {
  const messages = useCommaMessages();
  return (
    <MenuTrigger>
      <AriaButton
        aria-label={`${columnLabel(column, messages)} ${messages.task_feed_column_options()}`}
        className={HEADER_ICON_BUTTON_CLASS}
        data-slot="task-feed-column-menu-trigger"
      >
        <MoreHorizontalIcon aria-hidden className="size-4" />
      </AriaButton>
      <MenuPopover offset={spacing.xs} placement="bottom end">
        <Menu
          aria-label={messages.task_feed_column_options()}
          onAction={(key) => {
            if (key === "caught-up") onMarkCaughtUp?.();
            if (key === "hide") onHide?.();
          }}
        >
          {onMarkCaughtUp ? (
            <MenuItem id="caught-up">{messages.task_feed_mark_caught_up()}</MenuItem>
          ) : null}
          {onHide ? (
            <MenuItem id="hide">{messages.task_feed_column_hide()}</MenuItem>
          ) : null}
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}

function FeedSkeleton() {
  return (
    <div
      className="flex h-full min-h-0 justify-center gap-xl overflow-hidden px-2xl pt-lg pb-2xl"
      data-slot="task-feed-loading"
    >
      {[0, 1, 2].map((col) => (
        <div className={cx("flex h-full flex-col", DECK_COLUMN_WIDTH_CLASS)} key={col}>
          <div className="mb-md flex h-7 items-center gap-md px-md">
            <div className="h-4 w-24 animate-pulse rounded bg-secondary" />
          </div>
          <div className="flex flex-1 flex-col gap-lg">
            {[0, 1, 2].map((item) => (
              <div
                className={cx(
                  "grid grid-cols-[2.25rem_minmax(0,1fr)] gap-x-lg px-2xl py-xl",
                  taskCardSurface
                )}
                key={item}
              >
                <div className="size-9 animate-pulse rounded-full bg-secondary" />
                <div className="flex flex-col gap-2.5">
                  <div className="h-4 w-48 animate-pulse rounded bg-secondary" />
                  <div className="h-3.5 w-full animate-pulse rounded bg-secondary" />
                  <div className="h-3.5 w-3/4 animate-pulse rounded bg-secondary" />
                </div>
              </div>
            ))}
          </div>
        </div>
      ))}
      {/* Keeps column widths stable when the manage-columns button appears. */}
      <div aria-hidden className="w-7 shrink-0" />
    </div>
  );
}

export function TaskFeedView({
  allowedColumns,
  className,
  defaultExpandedEntryIds,
  defaultReplyEntryId,
  defaultRevealMessageId,
  defaultSelectedEntryId,
  defaultVisibleColumns,
  entries,
  filterActive = false,
  hasMore = false,
  lastSeenAt,
  loadError,
  loadMoreError,
  loadMorePending = false,
  loading = false,
  onApproveEntry,
  onLoadMore,
  onMarkCaughtUp,
  onOpenEntry,
  onReplyEntry,
  onRetry,
  onRevealMilestone,
  renderFile,
  renderMedia,
  renderPullRequest,
  renderSessionInspector,
}: TaskFeedViewProps) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();

  const [visibleColumns, setVisibleColumns] = useState<TaskFeedColumnId[]>(() => {
    const initial =
      defaultVisibleColumns && defaultVisibleColumns.length > 0
        ? defaultVisibleColumns.filter((col): col is TaskFeedColumnId =>
            ALL_COLUMNS.includes(col)
          )
        : DEFAULT_VISIBLE_COLUMNS;
    return initial.length > 0 ? [...initial] : [...DEFAULT_VISIBLE_COLUMNS];
  });
  const [narrowColumn, setNarrowColumn] = useState<TaskFeedColumnId>(
    () => visibleColumns[0] ?? "needs_review"
  );

  // Per-column in-column drill-in state (Meta Threads native push inside each column!).
  const [inspectedByColumn, setInspectedByColumn] = useState<
    Partial<Record<TaskFeedColumnId, ColumnDrillState>>
  >(() => {
    if (!defaultSelectedEntryId) return {};
    const target = entries.find((item) => item.id === defaultSelectedEntryId);
    if (!target || !ALL_COLUMNS.includes(target.statusBucket as TaskFeedColumnId)) {
      return {};
    }
    return {
      [target.statusBucket as TaskFeedColumnId]: {
        entryId: target.id,
        revealMessageId: defaultRevealMessageId,
      },
    };
  });
  const [inspectStack, setInspectStack] = useState<TaskFeedColumnId[]>(() => {
    if (!defaultSelectedEntryId) return [];
    const target = entries.find((item) => item.id === defaultSelectedEntryId);
    if (!target || !ALL_COLUMNS.includes(target.statusBucket as TaskFeedColumnId)) {
      return [];
    }
    return [target.statusBucket as TaskFeedColumnId];
  });

  const [expandedIds, setExpandedIds] = useState<Set<string>>(
    () => new Set(defaultExpandedEntryIds ?? [])
  );

  const containerRef = useRef<HTMLElement | null>(null);
  const [isNarrow, setIsNarrow] = useState<boolean>(false);

  const [scrolledAway, setScrolledAway] = useState(false);
  const [pendingNewCount, setPendingNewCount] = useState(0);
  const previousTopIdRef = useRef<string | undefined>(entries[0]?.id);
  const columnScrollRefs = useRef<Map<TaskFeedColumnId, HTMLElement>>(new Map());
  const narrowScrollRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const updateNarrow = () => {
      const nextWidth = el.clientWidth;
      if (nextWidth > 0) setIsNarrow(nextWidth < 768);
    };
    updateNarrow();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(updateNarrow);
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  const sortedEntries = useMemo(
    () =>
      [...entries].toSorted(
        (a, b) =>
          (normalizeEpochMs(b.occurredAt) ?? 0) - (normalizeEpochMs(a.occurredAt) ?? 0)
      ),
    [entries]
  );

  const entriesByColumn = useMemo(() => {
    const map: Record<TaskFeedColumnId, TaskFeedEntry[]> = {
      needs_review: [],
      in_progress: [],
      done: [],
      cancelled: [],
    };
    for (const entry of sortedEntries) {
      if (entry.statusBucket in map) {
        map[entry.statusBucket as TaskFeedColumnId].push(entry);
      }
    }
    return map;
  }, [sortedEntries]);

  const effectiveColumns = useMemo(() => {
    const base =
      allowedColumns !== undefined
        ? ALL_COLUMNS.filter((col) => allowedColumns.includes(col))
        : visibleColumns;
    if (filterActive) {
      const nonEmpty = base.filter((col) => entriesByColumn[col].length > 0);
      return nonEmpty.length > 0 ? nonEmpty : base;
    }
    return base;
  }, [allowedColumns, entriesByColumn, filterActive, visibleColumns]);

  useEffect(() => {
    if (effectiveColumns.length > 0 && !effectiveColumns.includes(narrowColumn)) {
      setNarrowColumn(effectiveColumns[0]!);
    }
  }, [effectiveColumns, narrowColumn]);

  const entryById = useMemo(() => {
    const map = new Map<string, TaskFeedEntry>();
    for (const entry of sortedEntries) {
      map.set(entry.id, entry);
    }
    return map;
  }, [sortedEntries]);

  useEffect(() => {
    const currentTopId = sortedEntries[0]?.id;
    const previousTopId = previousTopIdRef.current;
    previousTopIdRef.current = currentTopId;
    if (!previousTopId || !currentTopId || currentTopId === previousTopId) return;
    if (!scrolledAway) return;
    const previousIndex = sortedEntries.findIndex((item) => item.id === previousTopId);
    if (previousIndex > 0) {
      setPendingNewCount((count) => count + previousIndex);
    }
  }, [scrolledAway, sortedEntries]);

  const hideColumn = useCallback((column: TaskFeedColumnId) => {
    setVisibleColumns((prev) => {
      if (prev.length <= 1) return prev;
      return prev.filter((item) => item !== column);
    });
  }, []);

  const openColumnDrillIn = useCallback(
    (column: TaskFeedColumnId, entry: TaskFeedEntry, messageId?: string) => {
      setInspectedByColumn((prev) => ({
        ...prev,
        [column]: { entryId: entry.id, revealMessageId: messageId },
      }));
      setInspectStack((prev) => [...prev.filter((item) => item !== column), column]);
    },
    []
  );

  const closeColumnDrillIn = useCallback((column: TaskFeedColumnId) => {
    setInspectedByColumn((prev) => {
      if (!prev[column]) return prev;
      const next = { ...prev };
      delete next[column];
      return next;
    });
    setInspectStack((prev) => prev.filter((item) => item !== column));
  }, []);

  const handleSelectEntry = useCallback(
    (column: TaskFeedColumnId, entry: TaskFeedEntry, messageId?: string) => {
      if (renderSessionInspector) {
        openColumnDrillIn(column, entry, messageId);
        return;
      }
      if (messageId && onRevealMilestone) {
        onRevealMilestone(entry, messageId);
      } else {
        onOpenEntry?.(entry, messageId);
      }
    },
    [onOpenEntry, onRevealMilestone, openColumnDrillIn, renderSessionInspector]
  );

  const handleSelectMilestone = useCallback(
    (column: TaskFeedColumnId, entry: TaskFeedEntry, messageId: string) => {
      if (renderSessionInspector) {
        openColumnDrillIn(column, entry, messageId);
        return;
      }
      if (onRevealMilestone) {
        onRevealMilestone(entry, messageId);
      } else {
        onOpenEntry?.(entry, messageId);
      }
    },
    [onOpenEntry, onRevealMilestone, openColumnDrillIn, renderSessionInspector]
  );

  const handleExpandedChange = useCallback((entryId: string, expanded: boolean) => {
    setExpandedIds((prev) => {
      const next = new Set(prev);
      if (expanded) {
        next.add(entryId);
      } else {
        next.delete(entryId);
      }
      return next;
    });
  }, []);

  // Escape pops the most recently drilled-in column; open menus handle their own.
  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.metaKey || event.ctrlKey || event.altKey) return;
      if (isEditableElement(event.target)) return;

      if (event.key === "Escape") {
        const topColumn = inspectStack[inspectStack.length - 1];
        if (topColumn) {
          event.preventDefault();
          closeColumnDrillIn(topColumn);
        }
      }
    };

    document.addEventListener("keydown", handleKeyDown);
    return () => document.removeEventListener("keydown", handleKeyDown);
  }, [closeColumnDrillIn, inspectStack]);

  const scrollAllColumnsToTop = useCallback(() => {
    for (const el of columnScrollRefs.current.values()) {
      el.scrollTo({ top: 0, behavior: "smooth" });
    }
    narrowScrollRef.current?.scrollTo({ top: 0, behavior: "smooth" });
    setScrolledAway(false);
    setPendingNewCount(0);
  }, []);

  const handleColumnScroll = useCallback((scrollTop: number) => {
    if (scrollTop > 120) {
      setScrolledAway(true);
    } else if (scrollTop <= 24) {
      setScrolledAway(false);
      setPendingNewCount(0);
    }
  }, []);

  const normalizedLastSeenAt =
    lastSeenAt !== undefined ? normalizeEpochMs(lastSeenAt) : undefined;

  const columnCounts = useMemo(
    () => ({
      needs_review: entriesByColumn.needs_review.length,
      in_progress: entriesByColumn.in_progress.length,
      done: entriesByColumn.done.length,
      cancelled: entriesByColumn.cancelled.length,
    }),
    [entriesByColumn]
  );
  const manageColumns = !filterActive ? (
    <ManageColumnsMenu
      counts={columnCounts}
      onChange={setVisibleColumns}
      visibleColumns={visibleColumns}
    />
  ) : null;

  const buildInspectorContext = useCallback(
    (
      column: TaskFeedColumnId,
      entry: TaskFeedEntry,
      revealMessageId?: string
    ): TaskFeedSessionInspectorContext => ({
      entry,
      onApproveEntry,
      onClose: () => closeColumnDrillIn(column),
      onOpenFullTask: onOpenEntry,
      onReplyEntry,
      revealMessageId,
    }),
    [closeColumnDrillIn, onApproveEntry, onOpenEntry, onReplyEntry]
  );

  const renderColumnEntries = (
    column: TaskFeedColumnId,
    items: TaskFeedEntry[]
  ): ReactNode => {
    if (items.length === 0) {
      return (
        <div
          className="flex flex-1 items-center justify-center px-6 py-2xl text-center"
          data-slot="task-feed-column-empty"
        >
          <p className="m-0 text-sm text-tertiary">
            {columnEmptyLabel(column, messages)}
          </p>
        </div>
      );
    }

    return (
      <div className="flex flex-col gap-lg pb-lg" data-slot="task-feed-column-posts">
        {items.map((entry) => {
          const occurredAtMs = normalizeEpochMs(entry.occurredAt);
          const isUnread =
            normalizedLastSeenAt !== undefined &&
            occurredAtMs !== undefined &&
            occurredAtMs > normalizedLastSeenAt;
          return (
            <TaskFeedEntryRow
              defaultReplyOpen={defaultReplyEntryId === entry.id}
              entry={entry}
              expanded={expandedIds.has(entry.id)}
              key={entry.id}
              onApproveEntry={onApproveEntry}
              onExpandedChange={(next) => handleExpandedChange(entry.id, next)}
              onOpenFullTask={onOpenEntry}
              onReplyEntry={onReplyEntry}
              onSelectEntry={(target, messageId) =>
                handleSelectEntry(column, target, messageId)
              }
              onSelectMilestone={(target, messageId) =>
                handleSelectMilestone(column, target, messageId)
              }
              renderFile={renderFile}
              renderMedia={renderMedia}
              renderPullRequest={renderPullRequest}
              unread={isUnread}
            />
          );
        })}
      </div>
    );
  };

  const [feedSizeRevision, setFeedSizeRevision] = useState(0);
  const onColumnViewportResize = useCallback(
    () => setFeedSizeRevision((revision) => revision + 1),
    []
  );
  const canLoadMore = hasMore && onLoadMore !== undefined;
  const loadMoreFailed = loadMoreError !== undefined;
  const loadNextPage = useCallback(() => void onLoadMore?.(), [onLoadMore]);
  const pageEnd = (onlyWhenScrollable = false) =>
    onLoadMore ? (
      <ScrollAreaLoadMore
        className="py-md"
        failed={loadMoreFailed}
        hasMore={hasMore}
        loading={loadMorePending}
        onLoadMore={loadNextPage}
        onlyWhenScrollable={onlyWhenScrollable}
      />
    ) : null;

  useEffect(() => {
    const root = containerRef.current;
    if (
      isNarrow ||
      !root ||
      !canLoadMore ||
      loadMorePending ||
      loadMoreFailed ||
      loading ||
      (loadError && entries.length === 0)
    ) {
      return;
    }
    const columns = root.querySelectorAll<HTMLElement>(
      '[data-slot="task-feed-column"] [data-slot="scroll-area-viewport"]'
    );
    if (columns.length === 0) return;
    for (const column of columns) {
      if (column.scrollHeight > column.clientHeight) return;
    }
    loadNextPage();
  }, [
    canLoadMore,
    effectiveColumns,
    entries.length,
    feedSizeRevision,
    inspectedByColumn,
    isNarrow,
    loadError,
    loadMoreFailed,
    loadMorePending,
    loadNextPage,
    loading,
  ]);

  const narrowDrill = inspectedByColumn[narrowColumn];
  const narrowDrilledEntry = narrowDrill
    ? entryById.get(narrowDrill.entryId)
    : undefined;

  return (
    <section
      aria-label={messages.task_feed_region()}
      className={cx(
        "@container relative flex size-full min-h-0 flex-col bg-todo-kanban-bg-column-primary",
        className
      )}
      data-slot="task-feed"
      data-testid="tasks-feed"
      ref={containerRef}
    >
      {pendingNewCount > 0 ? (
        <div className="pointer-events-none absolute inset-x-0 top-4 z-20 flex justify-center">
          <button
            className="pointer-events-auto inline-flex cursor-pointer items-center gap-xs rounded-full border border-primary bg-popup-primary px-md py-xs text-xs font-medium text-primary shadow-md transition-colors hover:bg-secondary-hover focus-visible:outline-none focus-visible:shadow-focus-gray"
            data-slot="task-feed-new-updates"
            onClick={scrollAllColumnsToTop}
            type="button"
          >
            <ArrowUpIcon aria-hidden className="size-3.5 text-primary" />
            <span>
              {messages.task_feed_new_updates({
                count: pendingNewCount,
                formattedCount: formatNumber(pendingNewCount, locale),
              })}
            </span>
          </button>
        </div>
      ) : null}

      {loadError && entries.length === 0 ? (
        <div
          className="flex flex-1 flex-col items-center justify-center gap-md px-xl text-center"
          data-slot="task-feed-error"
        >
          <p className="m-0 text-sm font-medium text-primary">
            {messages.task_feed_error_title()}
          </p>
          <p className="m-0 max-w-[360px] text-xs text-tertiary">
            {loadError || messages.task_feed_error_description()}
          </p>
          {onRetry ? (
            <Button
              hierarchy="secondary-gray"
              onPress={() => {
                void Promise.resolve(onRetry()).catch(() => undefined);
              }}
              size="sm"
            >
              {messages.common_retry()}
            </Button>
          ) : null}
        </div>
      ) : loading && entries.length === 0 ? (
        <FeedSkeleton />
      ) : entries.length === 0 && !filterActive ? (
        <div
          className="flex flex-1 flex-col items-center justify-center gap-xs px-xl text-center"
          data-slot="task-feed-empty"
        >
          <p className="m-0 text-sm font-medium text-primary">
            {messages.task_feed_empty_title()}
          </p>
          <p className="m-0 max-w-90 text-xs text-tertiary">
            {messages.task_feed_empty_description()}
          </p>
        </div>
      ) : !isNarrow ? (
        /* DESKTOP (>= 768px): Pure Meta Threads Multi-Column Deck with In-Column Session Drill-In */
        <div
          className="flex min-h-0 flex-1 overflow-hidden"
          data-slot="task-feed-desktop-deck"
        >
          <ScrollArea
            className="min-w-0 flex-1"
            contentClassName="flex h-full min-h-0 w-full items-stretch justify-center-safe gap-xl px-2xl pt-lg pb-2xl"
            contentStyle={{
              minWidth: deckMinWidth(effectiveColumns.length, Boolean(manageColumns)),
            }}
            edgeEffect="mask"
            orientation="horizontal"
          >
            {effectiveColumns.map((column) => {
              const items = entriesByColumn[column];
              const drill = inspectedByColumn[column];
              const drilledEntry =
                drill && renderSessionInspector
                  ? entryById.get(drill.entryId)
                  : undefined;
              const isDrilledIn = Boolean(drilledEntry && renderSessionInspector);

              const hasUnreadInColumn =
                normalizedLastSeenAt !== undefined &&
                items.some((entry) => {
                  const ms = normalizeEpochMs(entry.occurredAt);
                  return ms !== undefined && ms > normalizedLastSeenAt;
                });
              const canHide = !filterActive && effectiveColumns.length > 1;
              const showColumnMenuButton =
                canHide || (hasUnreadInColumn && Boolean(onMarkCaughtUp));

              return (
                <div
                  className={cx(
                    "flex h-full min-h-0 flex-col",
                    DECK_COLUMN_WIDTH_CLASS
                  )}
                  data-column={column}
                  data-drilled-in={isDrilledIn ? "true" : "false"}
                  data-slot="task-feed-column"
                  key={column}
                >
                  {/* External Column Header: switches cleanly to ← ColumnName + Expand when drilled in */}
                  <header
                    className="mb-md flex h-7 shrink-0 items-center justify-between gap-sm pr-xs pl-md"
                    data-slot="task-feed-column-header"
                  >
                    {isDrilledIn && drilledEntry ? (
                      <>
                        <button
                          aria-label={messages.task_feed_back_to_column()}
                          className="-ml-sm inline-flex min-w-0 cursor-pointer items-center gap-sm rounded-md px-sm py-xs text-sm font-medium text-primary transition-colors hover:bg-secondary-hover focus-visible:shadow-focus-gray focus-visible:outline-none"
                          data-slot="task-feed-column-back"
                          onClick={() => closeColumnDrillIn(column)}
                          type="button"
                        >
                          <ArrowLeftIcon aria-hidden className="size-4 shrink-0" />
                          <span className="truncate">
                            {columnLabel(column, messages)}
                          </span>
                        </button>

                        <div className="flex shrink-0 items-center gap-xxs">
                          {onOpenEntry ? (
                            <button
                              aria-label={messages.task_feed_open_full_task()}
                              className="inline-flex size-7 cursor-pointer items-center justify-center rounded-full bg-transparent text-tertiary transition-colors hover:bg-secondary-hover hover:text-primary focus-visible:outline-none focus-visible:shadow-focus-gray"
                              data-slot="task-feed-column-expand"
                              onClick={() =>
                                onOpenEntry(drilledEntry, drill?.revealMessageId)
                              }
                              title={messages.task_feed_open_full_task()}
                              type="button"
                            >
                              <ExpandSimpleIcon aria-hidden className="size-4" />
                            </button>
                          ) : null}
                        </div>
                      </>
                    ) : (
                      <>
                        <div className="flex min-w-0 items-baseline gap-sm">
                          <h2 className="m-0 truncate text-sm font-medium text-primary">
                            {columnLabel(column, messages)}
                          </h2>
                          <span
                            className="shrink-0 text-xs tabular-nums text-quaternary"
                            data-slot="task-feed-column-count"
                          >
                            {formatNumber(items.length, locale)}
                          </span>
                        </div>

                        <div className="flex shrink-0 items-center gap-xxs">
                          {showColumnMenuButton ? (
                            <ColumnOptionsMenu
                              column={column}
                              onHide={canHide ? () => hideColumn(column) : undefined}
                              onMarkCaughtUp={
                                hasUnreadInColumn && onMarkCaughtUp
                                  ? () => void onMarkCaughtUp()
                                  : undefined
                              }
                            />
                          ) : null}
                        </div>
                      </>
                    )}
                  </header>

                  {/* Rounded Paper Column Container: hosts either Feed Stream OR Real Embedded Task Chat */}
                  <div
                    className={cx(
                      "flex min-h-0 flex-1 flex-col overflow-hidden rounded-xl",
                      isDrilledIn && drilledEntry && renderSessionInspector
                        ? taskCardSurface
                        : ""
                    )}
                  >
                    {isDrilledIn && drilledEntry && renderSessionInspector ? (
                      <div
                        className="flex size-full min-h-0 flex-1 flex-col overflow-hidden [&_.comma-scroll-area__content]:min-w-0! [&_.comma-scroll-area__content]:w-full"
                        data-entry-id={drilledEntry.id}
                        data-reveal-message-id={drill?.revealMessageId ?? ""}
                        data-slot="task-feed-column-chat"
                      >
                        {renderSessionInspector(
                          buildInspectorContext(
                            column,
                            drilledEntry,
                            drill?.revealMessageId
                          )
                        )}
                      </div>
                    ) : (
                      <ScrollArea
                        className="min-h-0 flex-1"
                        contentClassName="flex min-h-full w-full !min-w-0 flex-col"
                        edgeEffect="mask"
                        onScroll={(event) =>
                          handleColumnScroll(event.currentTarget.scrollTop)
                        }
                        onViewportResize={onColumnViewportResize}
                        orientation="vertical"
                        ref={(node) => {
                          if (node) {
                            columnScrollRefs.current.set(column, node);
                          } else {
                            columnScrollRefs.current.delete(column);
                          }
                        }}
                      >
                        {renderColumnEntries(column, items)}
                        {pageEnd(true)}
                      </ScrollArea>
                    )}
                  </div>
                </div>
              );
            })}

            {/* Mirrors the column header so the button centers on the cards. */}
            {manageColumns ? (
              <div className="flex shrink-0 flex-col self-stretch">
                <div aria-hidden className="mb-md h-7 shrink-0" />
                <div className="flex flex-1 items-center">{manageColumns}</div>
              </div>
            ) : null}
          </ScrollArea>
        </div>
      ) : (
        /* NARROW (< 768px): Minimalist Monochrome Threads Tabs + Single Rounded Column (with in-column drill-in) */
        <div className="flex min-h-0 flex-1 flex-col" data-slot="task-feed-narrow-view">
          {narrowDrilledEntry && renderSessionInspector ? (
            <div className="flex h-11 shrink-0 items-center justify-between gap-sm px-lg">
              <button
                aria-label={messages.task_feed_back_to_column()}
                className="-ml-sm inline-flex min-w-0 cursor-pointer items-center gap-sm rounded-md px-sm py-xs text-sm font-medium text-primary hover:bg-secondary-hover focus-visible:shadow-focus-gray focus-visible:outline-none"
                data-slot="task-feed-column-back"
                onClick={() => closeColumnDrillIn(narrowColumn)}
                type="button"
              >
                <ArrowLeftIcon aria-hidden className="size-4 shrink-0" />
                <span className="truncate">{columnLabel(narrowColumn, messages)}</span>
              </button>
              {onOpenEntry ? (
                <button
                  aria-label={messages.task_feed_open_full_task()}
                  className={HEADER_ICON_BUTTON_CLASS}
                  onClick={() =>
                    onOpenEntry(narrowDrilledEntry, narrowDrill?.revealMessageId)
                  }
                  type="button"
                >
                  <ExpandSimpleIcon aria-hidden className="size-4" />
                </button>
              ) : null}
            </div>
          ) : (
            <ScrollArea
              className="shrink-0"
              contentClassName="flex items-center gap-xs px-lg py-md"
              edgeEffect="mask"
              orientation="horizontal"
            >
              <div
                aria-label={messages.task_feed_region()}
                className="flex items-center gap-xs"
                role="tablist"
              >
                {effectiveColumns.map((col) => {
                  const active = narrowColumn === col;
                  const count = entriesByColumn[col].length;
                  return (
                    <button
                      aria-selected={active}
                      className={cx(
                        "inline-flex shrink-0 cursor-pointer items-baseline gap-sm rounded-full border px-lg py-xs text-sm font-medium whitespace-nowrap transition-colors focus-visible:shadow-focus-gray focus-visible:outline-none",
                        active
                          ? "border-secondary bg-todo-kanban-bg-card-primary text-primary shadow-xs"
                          : "border-transparent text-tertiary hover:bg-secondary-hover hover:text-primary"
                      )}
                      data-narrow-tab={col}
                      key={col}
                      onClick={() => setNarrowColumn(col)}
                      role="tab"
                      type="button"
                    >
                      <span>{columnLabel(col, messages)}</span>
                      <span className="text-xs font-normal tabular-nums text-quaternary">
                        {formatNumber(count, locale)}
                      </span>
                    </button>
                  );
                })}
              </div>
            </ScrollArea>
          )}

          <div
            className={cx(
              "mx-lg mb-lg flex min-h-0 flex-1 flex-col overflow-hidden rounded-xl",
              narrowDrilledEntry && renderSessionInspector ? taskCardSurface : ""
            )}
          >
            {narrowDrilledEntry && renderSessionInspector ? (
              <div
                className="flex size-full min-h-0 flex-1 flex-col overflow-hidden [&_.comma-scroll-area__content]:min-w-0! [&_.comma-scroll-area__content]:w-full"
                data-entry-id={narrowDrilledEntry.id}
                data-reveal-message-id={narrowDrill?.revealMessageId ?? ""}
                data-slot="task-feed-column-chat"
              >
                {renderSessionInspector(
                  buildInspectorContext(
                    narrowColumn,
                    narrowDrilledEntry,
                    narrowDrill?.revealMessageId
                  )
                )}
              </div>
            ) : (
              <ScrollArea
                className="min-h-0 flex-1"
                contentClassName="flex min-h-full w-full !min-w-0 flex-col"
                edgeEffect="mask"
                onScroll={(event) => handleColumnScroll(event.currentTarget.scrollTop)}
                orientation="vertical"
                ref={narrowScrollRef}
              >
                {renderColumnEntries(narrowColumn, entriesByColumn[narrowColumn])}
                {pageEnd(false)}
              </ScrollArea>
            )}
          </div>
        </div>
      )}
    </section>
  );
}
