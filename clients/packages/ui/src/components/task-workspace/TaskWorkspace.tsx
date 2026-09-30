import { TaskArchiveMenu } from "./TaskArchiveMenu";
import type { CommaLocale } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type MouseEvent,
  type ReactNode,
} from "react";
import { Button } from "../Button";
import { Checkbox } from "../checkbox";
import { ChatPanelMessageItem } from "../chat-panel";
import {
  ArchiveIcon,
  Cursor1Icon,
  ExclamationTriangleIcon,
  ListChecksIcon,
} from "../icons";
import { PageLoading } from "../PageLoading";
import { MarkdownStream, type MarkdownStreamClipboard } from "../markdown-stream";
import { ScrollArea, ScrollAreaLoadMore } from "../scroll-area";
import { SelectionBar, selectionBarButtonClasses } from "../selection-bar";
import { toast } from "../toast";
import {
  TaskBoard,
  TaskBoardColumn,
  TaskBoardToolbar,
  TaskCardReorderItem,
  TaskCardReorderList,
  applyManualOrder,
  type TaskView,
} from "../task-board";
import { TaskChatPanel } from "../task-chat-panel";
import { TaskListGroup, TaskListItem, type TaskListGroupProps } from "../TaskListItem";
import { cx } from "../utils";
import {
  TASK_STATUS_COLUMNS,
  TASK_WORKERS,
  TaskSummaryCard,
  taskAriaLabel,
  taskFreshnessLabel,
  taskStatusIcon,
  taskStatusLabel,
  taskUpdatedAtLabel,
  type TaskStatusBucket,
  type TaskSummaryViewModel,
  type TaskWorker,
  type TaskWorkspaceMessage,
} from "./TaskSummaryCard";
import {
  TaskWorkspaceToolbarActions,
  isTaskFilterSectionNarrowed,
  type TaskFilterSection,
} from "./TaskWorkspaceToolbarActions";

export type TaskWorkspaceTask = TaskSummaryViewModel & {
  conversationId: string;
  groupId: string;
  messages: TaskWorkspaceMessage[];
  workspaceId: string;
};

export type TaskWorkspaceProps = {
  capabilityState?: "ready" | "planned";
  className?: string;
  /** Extra filter dimensions (labels, platforms) the caller resolves and narrows by. */
  filterSections?: readonly TaskFilterSection[] | undefined;
  /** Chips under a card's title, e.g. its labels and where it was asked for. */
  renderTaskBadges?: ((task: TaskWorkspaceTask) => ReactNode) | undefined;
  hasMore?: boolean | undefined;
  initialTaskId?: string;
  initialStatus?: TaskStatusBucket | undefined;
  initialView?: TaskView;
  isDark?: boolean;
  loadError?: string | undefined;
  loadMoreError?: string | undefined;
  loadMorePending?: boolean | undefined;
  loading?: boolean | undefined;
  onCopyLink?: ((task: TaskWorkspaceTask) => Promise<void> | void) | undefined;
  codeClipboard?: MarkdownStreamClipboard | undefined;
  onChatWithComma?: (() => void) | undefined;
  onCreateTask?: (() => void) | undefined;
  onExpand?: ((task: TaskWorkspaceTask) => void) | undefined;
  onLoadMore?: (() => Promise<void> | void) | undefined;
  onOpenTask?: ((task: TaskWorkspaceTask) => void) | undefined;
  /** Visible navigation targets, for bounded preparation owned by the runtime. */
  onVisibleTasksChange?: ((tasks: readonly TaskWorkspaceTask[]) => void) | undefined;
  /**
   * Hands a multi-selection to the Comma assistant. Its presence turns
   * selection on: shift-click a card or a row (or tick a row's checkbox) to
   * start one, then plain clicks toggle until the bar is closed.
   */
  onAskComma?: ((tasks: readonly TaskWorkspaceTask[]) => void) | undefined;
  onRetry?: (() => Promise<void> | void) | undefined;
  onSendMessage?:
    | ((task: TaskWorkspaceTask, text: string) => Promise<void> | void)
    | undefined;
  /**
   * Persisted per-bucket card order to layer over the projection. When given
   * together with `onTaskOrderChange`, drops report there instead of into the
   * board's own session state.
   */
  taskOrder?: Partial<Record<TaskStatusBucket, readonly string[]>> | undefined;
  onTaskOrderChange?: ((bucket: TaskStatusBucket, ids: string[]) => void) | undefined;
  tasks?: readonly TaskWorkspaceTask[];
  userEmail?: string;
  /**
   * Worker values the caller can resolve from real task data. Omit this to
   * keep the Worker filter unavailable rather than exposing a non-functional
   * control.
   */
  workerFilterOptions?: readonly TaskWorker[];
};

const TASKS_NOT_CONNECTED_TOAST_ID = "tasks-not-connected";
const TASKS_SYNC_ERROR_TOAST_ID = "tasks-sync-error";

/**
 * Complete Tasks product surface. Runtime owners supply task projections and
 * side effects; this component owns the header, view switching, task content,
 * selection, and optional detail conversation.
 */
export function TaskWorkspace({
  capabilityState = "ready",
  className,
  filterSections = [],
  renderTaskBadges,
  hasMore = false,
  initialTaskId,
  initialView = "board",
  initialStatus,
  isDark = false,
  loadError,
  loadMoreError,
  loadMorePending = false,
  loading = false,
  onCopyLink,
  codeClipboard,
  onChatWithComma,
  onCreateTask,
  onExpand,
  onLoadMore,
  onAskComma,
  onOpenTask,
  onVisibleTasksChange,
  onRetry,
  onSendMessage,
  taskOrder,
  onTaskOrderChange,
  tasks = [],
  userEmail,
  workerFilterOptions,
}: TaskWorkspaceProps) {
  const rootRef = useRef<HTMLElement | null>(null);
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const [selectedTaskId, setSelectedTaskId] = useState<string | undefined>(
    initialTaskId
  );
  const [view, setView] = useState<TaskView>(initialView);
  const [selectedStatuses, setSelectedStatuses] = useState<
    ReadonlySet<TaskStatusBucket>
  >(
    () =>
      new Set(
        initialStatus
          ? [initialStatus]
          : TASK_STATUS_COLUMNS.map((column) => column.bucket)
      )
  );
  const [excludedWorkers, setExcludedWorkers] = useState<ReadonlySet<TaskWorker>>(
    () => new Set()
  );
  const [actionError, setActionError] = useState<string | undefined>();
  /**
   * Card order the user set by dragging, per column. It layers over the
   * projection's own order, which stays the source of truth for anything the
   * user has not moved: tasks that arrive later lead the column the way they
   * do by default, and the drop that follows folds them into the manual run.
   */
  const [internalOrder, setInternalOrder] = useState<
    Partial<Record<TaskStatusBucket, readonly string[]>>
  >({});
  const manualOrder = taskOrder ?? internalOrder;
  const selectedTask = tasks.find((task) => task.id === selectedTaskId);
  const hasTasks = tasks.length > 0;
  const availableWorkers = useMemo(
    () =>
      TASK_WORKERS.filter((worker) => workerFilterOptions?.includes(worker) ?? false),
    [workerFilterOptions]
  );
  const selectedWorkers = useMemo(
    () => new Set(availableWorkers.filter((worker) => !excludedWorkers.has(worker))),
    [availableWorkers, excludedWorkers]
  );

  useEffect(() => {
    setSelectedTaskId(initialTaskId);
    setActionError(undefined);
  }, [initialTaskId]);

  useEffect(() => {
    if (selectedTaskId && !tasks.some((task) => task.id === selectedTaskId)) {
      setSelectedTaskId(undefined);
    }
  }, [selectedTaskId, tasks]);

  const filteredTasks = useMemo(() => {
    const filtersByWorker =
      availableWorkers.length > 0 && selectedWorkers.size < availableWorkers.length;
    return tasks.filter(
      (task) =>
        selectedStatuses.has(task.statusBucket) &&
        (!filtersByWorker ||
          (task.worker !== undefined && selectedWorkers.has(task.worker)))
    );
  }, [availableWorkers.length, selectedStatuses, selectedWorkers, tasks]);
  // A column with nothing in it says nothing the toolbar's filter does not
  // already say, so the board only shows the ones holding cards.
  const sections = useMemo(
    () =>
      groupTasksByStatus(filteredTasks, selectedStatuses)
        .filter(({ tasks: sectionTasks }) => sectionTasks.length > 0)
        .map(({ column, tasks: sectionTasks }) => {
          const ordered = applyManualOrder(sectionTasks, manualOrder[column.bucket]);
          return { column, tasks: ordered, ids: ordered.map((task) => task.id) };
        }),
    [filteredTasks, manualOrder, selectedStatuses]
  );
  const statusCounts = useMemo(() => countTasksByStatus(tasks), [tasks]);
  const workerCounts = useMemo(() => countTasksByWorker(tasks), [tasks]);
  const visibleError = loadError ?? loadMoreError ?? actionError;
  const showEmptyState = !hasTasks && !loading && !visibleError;
  const showLoadingState = !hasTasks && loading;
  const showErrorState = !hasTasks && Boolean(visibleError);
  // Degraded states surface as persistent toasts (the board itself stays
  // usable) and dismiss themselves once the condition clears.
  useEffect(() => {
    if (capabilityState !== "planned") {
      toast.dismiss(TASKS_NOT_CONNECTED_TOAST_ID);
      return undefined;
    }
    toast.info(messages.tasks_not_connected(), {
      duration: Number.POSITIVE_INFINITY,
      id: TASKS_NOT_CONNECTED_TOAST_ID,
      testId: "tasks-not-connected",
    });
    return () => {
      toast.dismiss(TASKS_NOT_CONNECTED_TOAST_ID);
    };
  }, [capabilityState, messages]);
  const degradedError = hasTasks ? visibleError : undefined;
  useEffect(() => {
    if (!degradedError) {
      toast.dismiss(TASKS_SYNC_ERROR_TOAST_ID);
      return undefined;
    }
    toast.error(degradedError, {
      duration: Number.POSITIVE_INFINITY,
      id: TASKS_SYNC_ERROR_TOAST_ID,
      testId: "tasks-sync-error",
    });
    return () => {
      toast.dismiss(TASKS_SYNC_ERROR_TOAST_ID);
    };
  }, [degradedError]);

  const selectTask = useCallback(
    (task: TaskWorkspaceTask) => {
      if (onOpenTask) {
        onOpenTask(task);
        return;
      }
      setSelectedTaskId(task.id);
      setActionError(undefined);
    },
    [onOpenTask]
  );

  // Multi-selection: ids the reader has checked, kept only while their Tasks
  // are still on show. Shift-click starts one; while one stands, a plain
  // click toggles instead of opening, so a run of picks needs no modifier.
  const [checkedIds, setCheckedIds] = useState<ReadonlySet<string>>(() => new Set());
  const checkedTasks = useMemo(
    () => (onAskComma ? tasks.filter((task) => checkedIds.has(task.id)) : []),
    [checkedIds, onAskComma, tasks]
  );
  const selecting = checkedTasks.length > 0;
  // Read committed selection mode without replacing every row's click handler.
  const selectingRef = useRef(selecting);
  useLayoutEffect(() => {
    selectingRef.current = selecting;
  }, [selecting]);
  const clearChecked = useCallback(() => setCheckedIds(new Set()), []);
  const toggleChecked = useCallback((task: TaskWorkspaceTask, checked?: boolean) => {
    setCheckedIds((current) => {
      const next = new Set(current);
      if (checked ?? !next.has(task.id)) next.add(task.id);
      else next.delete(task.id);
      return next;
    });
  }, []);
  // Archive runs each checked Task's own action, the one its card menu
  // offers; a Task that cannot be archived yet (still running, on a schedule)
  // is left in place and counted in a notice.
  const archivableChecked = useMemo(
    () =>
      checkedTasks.filter(
        (task) => task.archiveAction !== undefined && !task.archiveAction.disabledReason
      ),
    [checkedTasks]
  );
  const [archivingChecked, setArchivingChecked] = useState(false);
  const archiveChecked = async () => {
    const skipped = checkedTasks.length - archivableChecked.length;
    setArchivingChecked(true);
    try {
      await Promise.allSettled(
        archivableChecked.map((task) => task.archiveAction!.run())
      );
    } finally {
      setArchivingChecked(false);
      clearChecked();
    }
    if (skipped > 0) {
      toast.warning(
        messages.tasks_archive_selected_skipped({ count: String(skipped) }),
        {
          id: "tasks-archive-selected-skipped",
          testId: "tasks-archive-selected-skipped",
        }
      );
    }
  };
  const pressTask = useCallback(
    (task: TaskWorkspaceTask, event: MouseEvent | KeyboardEvent) => {
      if (onAskComma && (event.shiftKey || selectingRef.current)) {
        toggleChecked(task);
        return;
      }
      selectTask(task);
    },
    [onAskComma, toggleChecked, selectTask]
  );
  useEffect(() => {
    if (!selecting) return undefined;
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      if (event.key === "Escape") clearChecked();
    };
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [clearChecked, selecting]);

  const toolbarActions = (
    <>
      <TaskWorkspaceToolbarActions
        filterSections={filterSections}
        onSelectedStatusesChange={setSelectedStatuses}
        onSelectedWorkersChange={(workers) =>
          setExcludedWorkers(
            new Set(availableWorkers.filter((worker) => !workers.has(worker)))
          )
        }
        onViewChange={setView}
        selectedStatuses={selectedStatuses}
        selectedWorkers={selectedWorkers}
        statusCounts={statusCounts}
        view={view}
        workerFilterOptions={availableWorkers}
        workerCounts={workerCounts}
      />
    </>
  );

  // The next page loads as the reader reaches the end of the list. On the
  // board every column scrolls on its own over one shared page, so only a
  // column that scrolls asks for more when its end comes into view (a short
  // column's end is always in view). A board none of whose columns scrolls
  // has no end to reach: it pages on until one does or the list ends.
  // Resize can remove the last scrollable column without changing the tasks.
  // Recheck once React commits the shared ScrollArea resize notifications.
  const [boardSizeRevision, setBoardSizeRevision] = useState(0);
  const onColumnViewportResize = useCallback(
    () => setBoardSizeRevision((revision) => revision + 1),
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
    const root = rootRef.current;
    if (view !== "board" || !root || !canLoadMore || loadMorePending || loadMoreFailed)
      return;
    const columns = root.querySelectorAll<HTMLElement>(
      '[data-slot="task-board-column"] [data-slot="scroll-area-viewport"]'
    );
    if (columns.length === 0) return;
    for (const column of columns) if (column.scrollHeight > column.clientHeight) return;
    loadNextPage();
  }, [
    canLoadMore,
    loadMoreFailed,
    loadMorePending,
    loadNextPage,
    sections,
    view,
    boardSizeRevision,
  ]);

  useEffect(() => {
    const root = rootRef.current;
    if (!root || !onVisibleTasksChange || typeof IntersectionObserver === "undefined")
      return;
    const nodes = [...root.querySelectorAll<HTMLElement>("[data-task-navigation-id]")];
    const visible = new Set<string>();
    const byId = new Map(tasks.map((task) => [task.id, task]));
    let intentId: string | undefined;
    const publish = () => {
      const ordered = nodes.flatMap((node) => {
        const id = node.dataset.taskNavigationId!;
        const task = visible.has(id) ? byId.get(id) : undefined;
        return task ? [task] : [];
      });
      const intent = ordered.find((task) => task.id === intentId);
      onVisibleTasksChange(
        intent ? [intent, ...ordered.filter((task) => task !== intent)] : ordered
      );
    };
    const prioritize = (event: Event) => {
      const id =
        event.target instanceof Element
          ? event.target.closest<HTMLElement>("[data-task-navigation-id]")?.dataset
              .taskNavigationId
          : undefined;
      if (id && id !== intentId) {
        intentId = id;
        publish();
      }
    };
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          const id = (entry.target as HTMLElement).dataset.taskNavigationId!;
          if (entry.isIntersecting) visible.add(id);
          else visible.delete(id);
        }
        publish();
      },
      { root, threshold: 0.01 }
    );
    root.addEventListener("pointerover", prioritize);
    root.addEventListener("focusin", prioritize);
    for (const node of nodes) observer.observe(node);
    return () => {
      observer.disconnect();
      root.removeEventListener("pointerover", prioritize);
      root.removeEventListener("focusin", prioritize);
      onVisibleTasksChange([]);
    };
  }, [onVisibleTasksChange, sections, tasks, view]);

  return (
    <section
      ref={rootRef}
      aria-label={messages.tasks_region()}
      className={cx(
        "relative flex h-full min-h-0 w-full min-w-0 flex-1 flex-col bg-main-panel-bg",
        className
      )}
      aria-busy={loading || undefined}
      data-slot="task-workspace"
      data-testid="tasks-route"
    >
      <div className="flex min-h-0 min-w-0 flex-1">
        <div className="flex min-h-0 min-w-0 flex-1 flex-col">
          <TaskBoardToolbar
            actions={toolbarActions}
            label={
              selectedStatuses.size === TASK_STATUS_COLUMNS.length &&
              selectedWorkers.size === availableWorkers.length &&
              !filterSections.some(isTaskFilterSectionNarrowed)
                ? messages.tasks_all()
                : messages.tasks_filtered()
            }
          />

          <div className="min-h-0 min-w-0 flex-1">
            {showLoadingState ? (
              <TaskWorkspaceLoadingState />
            ) : showErrorState ? (
              <TaskWorkspaceErrorState onRetry={onRetry} />
            ) : showEmptyState ? (
              <>
                <TaskWorkspaceEmptyState
                  onChatWithComma={onChatWithComma}
                  onCreateTask={onCreateTask}
                />
                {pageEnd()}
              </>
            ) : !hasTasks ? null : sections.length === 0 ? (
              <>
                <TaskWorkspaceFilterEmptyState />
                {pageEnd()}
              </>
            ) : view === "board" ? (
              <TaskBoard className="size-full" scrollAreaProps={{ edgeEffect: "mask" }}>
                {sections.map(({ column, tasks: sectionTasks, ids }) => (
                  <TaskBoardColumn
                    scrollAreaProps={{ onViewportResize: onColumnViewportResize }}
                    count={sectionTasks.length}
                    icon={column.icon}
                    key={column.bucket}
                    label={taskStatusLabel(column.bucket, locale)}
                  >
                    <TaskCardReorderList
                      ids={ids}
                      onReorder={(orderedIds) =>
                        onTaskOrderChange
                          ? onTaskOrderChange(column.bucket, orderedIds)
                          : setInternalOrder((current) => ({
                              ...current,
                              [column.bucket]: orderedIds,
                            }))
                      }
                    >
                      {sectionTasks.map((task) => (
                        <TaskWorkspaceBoardRow
                          checked={checkedIds.has(task.id)}
                          key={task.id}
                          locale={locale}
                          onPress={pressTask}
                          renderTaskBadges={renderTaskBadges}
                          selected={task.id === selectedTaskId}
                          task={task}
                        />
                      ))}
                    </TaskCardReorderList>
                    {pageEnd(true)}
                  </TaskBoardColumn>
                ))}
              </TaskBoard>
            ) : (
              <ScrollArea
                className="size-full bg-primary"
                contentClassName="@container flex min-h-full flex-col gap-xs p-md"
                data-testid="tasks-list"
                edgeEffect="mask"
                orientation="vertical"
              >
                {sections.map(({ column, tasks: sectionTasks }) => (
                  <TaskListGroup
                    accent={taskStatusGroupAccent(column.bucket)}
                    count={sectionTasks.length}
                    defaultOpen
                    icon={column.icon}
                    key={column.bucket}
                    label={taskStatusLabel(column.bucket, locale)}
                  >
                    {sectionTasks.map((task) => (
                      <TaskWorkspaceListRow
                        renderTaskBadges={renderTaskBadges}
                        checked={checkedIds.has(task.id)}
                        key={task.id}
                        locale={locale}
                        onPress={pressTask}
                        {...(onAskComma ? { onToggleChecked: toggleChecked } : {})}
                        selected={task.id === selectedTaskId}
                        task={task}
                      />
                    ))}
                  </TaskListGroup>
                ))}
                {pageEnd()}
              </ScrollArea>
            )}
          </div>
        </div>

        {selectedTask ? (
          <TaskDetailPanel
            {...(codeClipboard ? { codeClipboard } : {})}
            isDark={isDark}
            onClose={() => setSelectedTaskId(undefined)}
            {...(onCopyLink ? { onCopyLink: () => onCopyLink(selectedTask) } : {})}
            onError={setActionError}
            {...(onExpand ? { onExpand: () => onExpand(selectedTask) } : {})}
            {...(onSendMessage
              ? {
                  onSendMessage: (text: string) => onSendMessage(selectedTask, text),
                }
              : {})}
            task={selectedTask}
            userEmail={userEmail ?? messages.task_you()}
          />
        ) : null}
      </div>
      {onAskComma && selecting ? (
        <SelectionBar
          aria-label={messages.tasks_selection_toolbar()}
          clearLabel={messages.tasks_clear_selection()}
          clearTestId="tasks-clear-selection"
          countLabel={messages.tasks_selected_count({
            count: String(checkedTasks.length),
          })}
          onClear={clearChecked}
          testId="tasks-selection-bar"
        >
          <button
            className={cx(selectionBarButtonClasses, "px-md")}
            data-testid="tasks-ask-comma"
            onClick={() => {
              onAskComma(checkedTasks);
              clearChecked();
            }}
            type="button"
          >
            <Cursor1Icon aria-hidden className="size-5" />
            <span className="px-xxs whitespace-nowrap">
              {messages.tasks_ask_comma()}
            </span>
          </button>
          <button
            className={cx(
              selectionBarButtonClasses,
              "px-md disabled:cursor-default disabled:opacity-50"
            )}
            data-testid="tasks-archive-selected"
            disabled={archivingChecked || archivableChecked.length === 0}
            onClick={() => void archiveChecked()}
            type="button"
          >
            <ArchiveIcon aria-hidden className="size-5" />
            <span className="px-xxs whitespace-nowrap">
              {messages.tasks_archive_selected()}
            </span>
          </button>
        </SelectionBar>
      ) : null}
    </section>
  );
}

function TaskWorkspaceCenteredState({
  children,
  className,
  role,
  slot,
}: {
  children: ReactNode;
  className?: string;
  role?: "alert";
  slot: string;
}) {
  return (
    <div
      className="flex size-full min-h-0 items-center justify-center p-xl"
      data-slot={slot}
      role={role}
    >
      <div
        className={cx("flex max-w-full flex-col items-center text-center", className)}
      >
        {children}
      </div>
    </div>
  );
}

function TaskWorkspaceLoadingState() {
  const messages = useCommaMessages();

  return (
    <PageLoading
      data-slot="task-workspace-loading-state"
      label={messages.tasks_loading()}
      indicator="spinner"
    />
  );
}

function TaskWorkspaceErrorState({
  onRetry,
}: {
  onRetry?: (() => Promise<void> | void) | undefined;
}) {
  const messages = useCommaMessages();

  return (
    <TaskWorkspaceCenteredState
      className="gap-xl"
      role="alert"
      slot="task-workspace-error-state"
    >
      <div className="flex flex-col items-center gap-md">
        <ExclamationTriangleIcon className="size-8 shrink-0 text-error-primary" />
        <h2 className="m-0 text-md font-medium leading-6 tracking-[-0.16px] text-primary">
          {messages.tasks_error_title()}
        </h2>
        <p className="m-0 max-w-[269px] text-balance text-sm font-regular leading-5 tracking-[-0.14px] text-tertiary">
          {onRetry ? messages.tasks_error_description() : messages.tasks_unavailable()}
        </p>
      </div>
      {onRetry ? (
        <Button
          className="h-auto px-lg py-xs"
          hierarchy="secondary-gray"
          onPress={onRetry}
          size="sm"
        >
          {messages.tasks_try_again()}
        </Button>
      ) : null}
    </TaskWorkspaceCenteredState>
  );
}

function TaskWorkspaceEmptyState({
  onChatWithComma,
  onCreateTask,
}: {
  onChatWithComma?: (() => void) | undefined;
  onCreateTask?: (() => void) | undefined;
}) {
  const messages = useCommaMessages();

  return (
    <TaskWorkspaceCenteredState className="gap-xl" slot="task-workspace-empty-state">
      <div className="flex flex-col items-center gap-md">
        <ListChecksIcon className="size-8 shrink-0 text-markdown-icon-primary" />
        <h2 className="m-0 text-md font-medium leading-6 tracking-[-0.16px] text-primary">
          {messages.tasks_empty()}
        </h2>
        <p className="m-0 max-w-[269px] text-sm font-regular leading-5 tracking-[-0.14px] text-tertiary">
          {messages.tasks_empty_description()}
        </p>
      </div>
      {onCreateTask || onChatWithComma ? (
        <div className="flex flex-wrap items-start justify-center gap-md">
          {onCreateTask ? (
            <Button className="h-auto px-md py-xs" onPress={onCreateTask} size="sm">
              {messages.tasks_create_new()}
            </Button>
          ) : null}
          {onChatWithComma ? (
            <Button
              className="h-auto px-lg py-xs"
              hierarchy="secondary-gray"
              onPress={onChatWithComma}
              size="sm"
            >
              {messages.tasks_chat_with_comma()}
            </Button>
          ) : null}
        </div>
      ) : null}
    </TaskWorkspaceCenteredState>
  );
}

function TaskWorkspaceFilterEmptyState() {
  const messages = useCommaMessages();

  return (
    <TaskWorkspaceCenteredState
      className="gap-md"
      slot="task-workspace-filter-empty-state"
    >
      <ListChecksIcon className="size-8 shrink-0 text-markdown-icon-primary" />
      <h2 className="m-0 text-md font-medium leading-6 tracking-[-0.16px] text-primary">
        {messages.tasks_empty()}
      </h2>
      <p className="m-0 max-w-[269px] text-sm font-regular leading-5 tracking-[-0.14px] text-tertiary">
        {messages.tasks_filter_no_matches()}
      </p>
    </TaskWorkspaceCenteredState>
  );
}

function groupTasksByStatus(
  tasks: readonly TaskWorkspaceTask[],
  visibleStatuses: ReadonlySet<TaskStatusBucket>
) {
  const grouped = new Map<TaskStatusBucket, TaskWorkspaceTask[]>(
    TASK_STATUS_COLUMNS.filter((column) => visibleStatuses.has(column.bucket)).map(
      (column) => [column.bucket, []]
    )
  );

  for (const task of tasks) {
    grouped.get(task.statusBucket)?.push(task);
  }

  return TASK_STATUS_COLUMNS.map((column) => ({
    column,
    tasks: grouped.get(column.bucket) ?? [],
  })).filter(({ column }) => visibleStatuses.has(column.bucket));
}

function countTasksByStatus(
  tasks: readonly TaskWorkspaceTask[]
): Record<TaskStatusBucket, number> {
  const counts: Record<TaskStatusBucket, number> = {
    backlog: 0,
    in_progress: 0,
    needs_review: 0,
    done: 0,
    cancelled: 0,
    archived: 0,
  };
  for (const task of tasks) counts[task.statusBucket] += 1;
  return counts;
}

function countTasksByWorker(
  tasks: readonly TaskWorkspaceTask[]
): Record<TaskWorker, number> {
  const counts: Record<TaskWorker, number> = { codex: 0, claude: 0 };
  for (const task of tasks) {
    if (task.worker) counts[task.worker] += 1;
  }
  return counts;
}

type TaskWorkspaceRowProps = {
  renderTaskBadges: TaskWorkspaceProps["renderTaskBadges"];
  checked: boolean;
  locale: CommaLocale;
  onPress: (task: TaskWorkspaceTask, event: MouseEvent | KeyboardEvent) => void;
  selected: boolean;
  task: TaskWorkspaceTask;
};

const TaskWorkspaceBoardRow = memo(function TaskWorkspaceBoardRow({
  checked,
  locale,
  onPress,
  renderTaskBadges,
  selected,
  task,
}: TaskWorkspaceRowProps) {
  return (
    <TaskCardReorderItem id={task.id}>
      <TaskArchiveMenu action={task.archiveAction}>
        <button
          aria-label={taskAriaLabel(task, locale)}
          className="group/task-card w-full border-0 bg-transparent p-0 text-left"
          data-task-navigation-id={task.id}
          data-freshness={task.freshness}
          data-checked={checked ? "true" : undefined}
          onClick={(event) => onPress(task, event)}
          type="button"
        >
          <TaskSummaryCard
            badges={renderTaskBadges?.(task)}
            interactive
            checked={checked}
            selected={selected}
            task={task}
          />
        </button>
      </TaskArchiveMenu>
    </TaskCardReorderItem>
  );
});

const TaskWorkspaceListRow = memo(function TaskWorkspaceListRow({
  renderTaskBadges,
  checked,
  locale,
  onPress,
  onToggleChecked,
  selected,
  task,
}: TaskWorkspaceRowProps & {
  /** Present when the list can be multi-selected: the row grows a checkbox. */
  onToggleChecked?: ((task: TaskWorkspaceTask, checked: boolean) => void) | undefined;
}) {
  const messages = useCommaMessages();
  const freshness = taskFreshnessLabel(task.freshness, locale);
  // With a checkbox inside, the row is a div playing button: a button may
  // not hold another control.
  const rowAs = onToggleChecked ? "div" : "button";
  return (
    <TaskArchiveMenu action={task.archiveAction}>
      <TaskListItem
        aria-label={taskAriaLabel(task, locale)}
        as={rowAs}
        badges={renderTaskBadges?.(task)}
        style={{
          contentVisibility: "auto",
          containIntrinsicBlockSize: "auto 1.25rem",
        }}
        checked={checked}
        data-task-navigation-id={task.id}
        data-freshness={task.freshness}
        icon={taskStatusIcon(task.statusBucket)}
        iconKey={task.statusBucket}
        layout="content"
        {...(onToggleChecked
          ? {
              leading: (
                <span
                  className={cx(
                    "flex shrink-0 items-center justify-center",
                    checked
                      ? "opacity-100"
                      : "opacity-0 group-hover/task-row:opacity-100 focus-within:opacity-100"
                  )}
                  onClick={(event) => event.stopPropagation()}
                  onKeyDown={(event) => event.stopPropagation()}
                  role="presentation"
                >
                  <Checkbox
                    aria-label={messages.tasks_select_task({ title: task.title })}
                    checked={checked}
                    onChange={(event) => onToggleChecked(task, event.target.checked)}
                    size="sm"
                  />
                </span>
              ),
              role: "button",
              tabIndex: 0,
              onKeyDown: (event: KeyboardEvent<HTMLDivElement>) => {
                if (event.target !== event.currentTarget) return;
                if (event.key === "Enter" || event.key === " ") {
                  event.preventDefault();
                  onPress(task, event);
                }
              },
            }
          : {})}
        className={onToggleChecked ? "group/task-row" : undefined}
        onClick={(event: MouseEvent) => onPress(task, event)}
        selected={selected}
        tail={
          <>
            {freshness ? (
              <span
                className={
                  task.freshness === "stale"
                    ? "shrink-0 whitespace-nowrap text-fg-warning-secondary"
                    : "shrink-0 whitespace-nowrap text-tertiary"
                }
              >
                {freshness}
              </span>
            ) : null}
            {task.updatedAt ? (
              <span className="shrink-0 whitespace-nowrap font-normal text-quaternary">
                {taskUpdatedAtLabel(task.updatedAt, locale)}
              </span>
            ) : null}
          </>
        }
        title={task.title}
      />
    </TaskArchiveMenu>
  );
});

function TaskDetailPanel({
  codeClipboard,
  isDark,
  onClose,
  onCopyLink,
  onError,
  onExpand,
  onSendMessage,
  task,
  userEmail,
}: {
  codeClipboard?: MarkdownStreamClipboard | undefined;
  isDark: boolean;
  onClose: () => void;
  onCopyLink?: (() => Promise<void> | void) | undefined;
  onError: (message: string | undefined) => void;
  onExpand?: (() => void) | undefined;
  onSendMessage?: ((text: string) => Promise<void> | void) | undefined;
  task: TaskWorkspaceTask;
  userEmail: string;
}) {
  const messages = useCommaMessages();
  const [reply, setReply] = useState("");
  const [sending, setSending] = useState(false);

  const sendReply = async (text: string) => {
    const message = text.trim();
    if (!message || sending || !onSendMessage) return;
    setSending(true);
    onError(undefined);
    try {
      await onSendMessage(message);
      setReply("");
    } catch (error) {
      onError(errorMessage(error));
    } finally {
      setSending(false);
    }
  };

  return (
    <TaskChatPanel
      aiInputProps={{
        "aria-label": messages.task_continue(),
        disabled: !onSendMessage,
        onSubmit: (text) => void sendReply(text),
        onValueChange: setReply,
        placeholder: messages.task_prompt_placeholder(),
        sendLabel: messages.task_send_message(),
        showAccessButton: false,
        showAttachButton: true,
        showVoiceButton: true,
        submitDisabled: sending,
        value: reply,
      }}
      className="w-[62.17%] shrink-0"
      onClose={onClose}
      {...(onCopyLink ? { onCopyLink: () => void onCopyLink() } : {})}
      {...(onExpand ? { onExpand } : {})}
      title={task.title}
    >
      {task.messages.length > 0 ? (
        task.messages.map((message) => (
          <ChatPanelMessageItem
            key={message.id}
            message={{
              author: message.role === "user" ? userEmail : message.roleLabel,
              content:
                message.role === "user" ? (
                  message.content
                ) : (
                  <MarkdownStream
                    animation="none"
                    {...(codeClipboard ? { clipboard: codeClipboard } : {})}
                    content={message.content}
                    final
                    isDark={isDark}
                    streamId={message.id}
                  />
                ),
              id: message.id,
              kind: message.role === "user" ? "user" : "assistant",
            }}
            variant="task"
          />
        ))
      ) : (
        <p className="m-0 text-sm text-tertiary">{messages.task_no_messages()}</p>
      )}
    </TaskChatPanel>
  );
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

const TASK_STATUS_GROUP_ACCENTS = {
  backlog: "neutral",
  in_progress: "neutral",
  needs_review: "warning",
  done: "success",
  archived: "neutral",
  cancelled: "error",
} satisfies Record<TaskStatusBucket, NonNullable<TaskListGroupProps["accent"]>>;

function taskStatusGroupAccent(bucket: TaskStatusBucket) {
  return TASK_STATUS_GROUP_ACCENTS[bucket];
}
