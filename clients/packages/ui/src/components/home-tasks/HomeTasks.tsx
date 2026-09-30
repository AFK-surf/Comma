import { messages } from "@comma/i18n";
import { useCommaLocale } from "@comma/i18n/react";
import {
  type CSSProperties,
  useCallback,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import { isReducedMotionEnabled, motionDuration, motionEasing } from "../../tokens";
import { PlusSmallIcon } from "../icons";
import {
  StatusIndicator,
  indicatorIdToTaskStatus,
  taskStatusToIndicatorId,
  type StatusId,
} from "../status-indicator";
import {
  TaskCardReorderItem,
  TaskCardReorderList,
  applyManualOrder,
} from "../task-board";
import type { TaskSummaryViewModel } from "../task-workspace/TaskSummaryCard";
import type { TaskStatusBucket } from "../task-workspace/taskStatus";
import { ScrollArea } from "../scroll-area";
import { HomeTaskCard } from "./HomeTaskCard";
import { HOME_TASKS_MAX_NEW_STAGGER } from "./useHomeTasksDisplay";
import {
  homeTasksAddButton,
  homeTasksAddIcon,
  homeTasksEmpty,
  homeTasksFooter,
  homeTasksHeader,
  homeTasksItem,
  homeTasksList,
  homeTasksPanel,
  homeTasksRoot,
  homeTasksTitle,
  homeTasksViewport,
} from "./styles";

import { useHomeTasksDisplay } from "./useHomeTasksDisplay";

/* Matches the shared list surfaces (e.g. the Inbox): a shallow fade where
   content scrolls in from the top, a deeper one above the status switcher. */
const EDGE_MASK = { endSize: 24, startSize: 16 };

export interface HomeTasksProps<T extends TaskSummaryViewModel = TaskSummaryViewModel> {
  onAddTask?: (() => void) | undefined;
  onOpenTask: (task: T) => void;
  onStatusChange: (bucket: TaskStatusBucket) => void;
  /** False while the task source is still loading; suppresses entry animations. */
  ready?: boolean;
  status: TaskStatusBucket;
  /** Persisted per-bucket card order to layer over the projection. */
  taskOrder?: Partial<Record<TaskStatusBucket, readonly string[]>> | undefined;
  onTaskOrderChange?: ((bucket: TaskStatusBucket, ids: string[]) => void) | undefined;
  /** Badges for one card beyond the worker badge; the Tasks board supplies the same. */
  renderTaskBadges?: ((task: T) => ReactNode) | undefined;
  tasks: readonly T[];
}

export function HomeTasks<T extends TaskSummaryViewModel>({
  onAddTask,
  onOpenTask,
  onStatusChange,
  ready = true,
  status,
  taskOrder,
  onTaskOrderChange,
  tasks,
  renderTaskBadges,
}: HomeTasksProps<T>) {
  const locale = useCommaLocale();
  /**
   * Card order the user set by dragging, per status. Session-local, like the
   * Tasks board: it layers over the projection's order, and tasks that arrive
   * later lead the stack until the next drop folds them in.
   */
  const [internalOrder, setInternalOrder] = useState<
    Partial<Record<TaskStatusBucket, readonly string[]>>
  >({});
  const manualOrder = taskOrder ?? internalOrder;
  const { current, direction, outgoing } = useHomeTasksDisplay(tasks, status, ready);
  // Ordering happens at render time so a drop lands in the same frame as its
  // settle animation — the display hook keeps owning what is new or leaving.
  const orderedEntries = useMemo(
    () =>
      applyManualOrder(
        current.entries,
        manualOrder[current.bucket],
        (entry) => entry.task.id
      ),
    [current.bucket, current.entries, manualOrder]
  );
  const itemRefs = useRef(new Map<string, HTMLLIElement>());
  const observedItemsRef = useRef(new Set<HTMLLIElement>());
  const visibilityObserverRef = useRef<IntersectionObserver | null>(null);
  const prevTopsRef = useRef(new Map<string, number>());
  /** True for the render right after a drag drop: its settle owns the motion. */
  const reorderSettlingRef = useRef(false);
  const currentViewportRef = useRef<HTMLDivElement>(null);
  const indicatorFocusedRef = useRef(false);
  const previousHasTasksRef = useRef(tasks.length > 0);
  const titleRef = useRef<HTMLHeadingElement>(null);
  const hasTasks = tasks.length > 0;

  // One observer owns the list's continuous effects. Clipped cards retain
  // their layout and focus targets without advancing their status animation.
  useLayoutEffect(() => {
    if (typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        // Threshold zero includes edge contact. The ratio can then grow
        // without another callback, so use the observer's intersection state.
        (entry.target as HTMLElement).dataset.motionVisible = String(
          entry.isIntersecting
        );
      }
    });
    visibilityObserverRef.current = observer;
    for (const element of observedItemsRef.current) {
      element.dataset.motionVisible = "false";
      observer.observe(element);
    }
    return () => {
      observer.disconnect();
      visibilityObserverRef.current = null;
    };
  }, []);

  const handleIndicatorChange = useCallback(
    (id: StatusId) => onStatusChange(indicatorIdToTaskStatus(id)),
    [onStatusChange]
  );

  // A controlled status change renders once with the old page still current;
  // the display hook promotes it to outgoing in a passive effect afterward.
  // A live update likewise renders before a removed card enters its leaving
  // phase. Move focus in that pre-transition layout phase so it never enters
  // hidden content or falls back to the document body after an unmount.
  useLayoutEffect(() => {
    const viewport = currentViewportRef.current;
    if (!viewport) return;
    const activeElement = viewport.ownerDocument.activeElement;
    if (!viewport.contains(activeElement)) return;

    if (status === current.bucket) {
      const focusedItemKey = Array.from(itemRefs.current.entries()).find(
        ([, element]) => element.contains(activeElement)
      )?.[0];
      const nextItemKeys = new Set(
        tasks
          .filter((task) => task.statusBucket === current.bucket)
          .map((task) => itemKey(current.stamp, task.id))
      );
      if (focusedItemKey ? nextItemKeys.has(focusedItemKey) : nextItemKeys.size > 0) {
        return;
      }
    }

    titleRef.current?.focus({ preventScroll: true });
  }, [current.bucket, current.stamp, status, tasks]);

  // Restore focus after the indicator disappears with the last task. Focus
  // events from its Shadow DOM are retargeted through the footer.
  useLayoutEffect(() => {
    const previouslyHadTasks = previousHasTasksRef.current;
    previousHasTasksRef.current = hasTasks;
    if (!previouslyHadTasks || hasTasks || !indicatorFocusedRef.current) return;

    indicatorFocusedRef.current = false;
    titleRef.current?.focus({ preventScroll: true });
  }, [hasTasks]);

  // FLIP pass: when cards shift because a sibling appeared or left, glide them
  // from their previous offset instead of letting the layout jump. Reading the
  // offsets forces a synchronous layout, so it runs only when what the cards
  // render changes; a parent re-render (the rail pausing while another page
  // shows) moves no card and must not stall that page's commit.
  useLayoutEffect(() => {
    const tops = new Map<string, number>();
    itemRefs.current.forEach((element, key) => {
      if (element.isConnected) tops.set(key, element.offsetTop);
    });
    const previous = prevTopsRef.current;
    prevTopsRef.current = tops;
    // A drag drop settles through the reorder list's own FLIP pass; gliding
    // the rows too would move every card twice.
    if (reorderSettlingRef.current) {
      reorderSettlingRef.current = false;
      return;
    }
    if (isReducedMotionEnabled()) return;

    for (const entry of current.entries) {
      // "new" runs its own entrance and "leaving" is fading in place; anything
      // else with a recorded previous offset glides to its new position.
      if (entry.state === "new" || entry.state === "leaving") continue;
      const key = itemKey(current.stamp, entry.task.id);
      const before = previous.get(key);
      const after = tops.get(key);
      if (before === undefined || after === undefined || before === after) continue;
      itemRefs.current
        .get(key)
        ?.animate(
          [
            { transform: `translateY(${before - after}px)` },
            { transform: "translateY(0)" },
          ],
          {
            duration: motionDuration.spatialMove,
            easing: motionEasing.surfaceSmoothOut,
          }
        );
    }
  }, [current.entries, current.stamp, locale, orderedEntries, renderTaskBadges]);

  // The glide compares each card's offset with the one recorded when the
  // cards last changed, and the rail renders only when its tasks or status
  // move. A window resize, or a narrower rail rewrapping card text, shifts
  // cards without a render, so the recorded offsets are refreshed then —
  // without animating — or the next arrival would glide cards from where they
  // stood before the resize.
  const refreshCardOffsets = useCallback(() => {
    const tops = new Map<string, number>();
    itemRefs.current.forEach((element, key) => {
      if (element.isConnected) tops.set(key, element.offsetTop);
    });
    prevTopsRef.current = tops;
  }, []);

  const registerItem = useCallback(
    (key: string, element: HTMLLIElement, trackLayout: boolean) => {
      if (trackLayout) itemRefs.current.set(key, element);
      observedItemsRef.current.add(element);
      if (visibilityObserverRef.current) {
        element.dataset.motionVisible = "false";
        visibilityObserverRef.current.observe(element);
      }
      return () => {
        if (itemRefs.current.get(key) === element) itemRefs.current.delete(key);
        observedItemsRef.current.delete(element);
        visibilityObserverRef.current?.unobserve(element);
      };
    },
    []
  );

  const showEmpty = ready && current.entries.length === 0;
  const handleReorder = useCallback(
    (ids: string[]) => {
      reorderSettlingRef.current = true;
      if (onTaskOrderChange) {
        onTaskOrderChange(current.bucket, ids);
        return;
      }
      setInternalOrder((currentOrder) => ({ ...currentOrder, [current.bucket]: ids }));
    },
    [current.bucket, onTaskOrderChange]
  );

  return (
    <section
      aria-label={messages.tasks_region(undefined, { locale })}
      className={homeTasksRoot}
      data-testid="home-tasks-section"
    >
      <header className={homeTasksHeader}>
        <h2 className={homeTasksTitle} ref={titleRef} tabIndex={-1}>
          {messages.tasks_title(undefined, { locale })}
        </h2>
        {onAddTask ? (
          <button
            aria-label={messages.tasks_create_new(undefined, { locale })}
            className={homeTasksAddButton}
            onClick={onAddTask}
            type="button"
          >
            <span aria-hidden className={homeTasksAddIcon}>
              <PlusSmallIcon />
            </span>
          </button>
        ) : null}
      </header>
      <div
        className={homeTasksViewport}
        style={{ "--comma-home-tasks-dir": direction } as CSSProperties}
      >
        {outgoing ? (
          <ScrollArea
            aria-hidden
            className={homeTasksPanel}
            data-role="outgoing"
            edgeEffect="mask"
            edgeMask={EDGE_MASK}
            inert
            key={`panel-${outgoing.stamp}`}
            orientation="vertical"
            viewportProps={{ tabIndex: -1 }}
          >
            <ul className={homeTasksList}>
              {applyManualOrder(outgoing.tasks, manualOrder[outgoing.bucket]).map(
                (task) => (
                  <HomeTasksItem
                    itemKey={itemKey(outgoing.stamp, task.id)}
                    key={itemKey(outgoing.stamp, task.id)}
                    register={registerItem}
                    trackLayout={false}
                  >
                    <HomeTaskCard
                      badges={renderTaskBadges?.(task)}
                      onOpen={onOpenTask}
                      task={task}
                    />
                  </HomeTasksItem>
                )
              )}
            </ul>
          </ScrollArea>
        ) : null}
        {showEmpty ? (
          // Keep one node across empty buckets so its entry fade only runs
          // when the empty state actually enters, not on every filter change.
          // With tasks in other buckets the rail is filtered, not empty, and
          // must not read as "you have no tasks".
          <p className={homeTasksEmpty}>
            {hasTasks
              ? messages.tasks_empty_status(undefined, { locale })
              : messages.tasks_empty(undefined, { locale })}
          </p>
        ) : (
          <ScrollArea
            className={homeTasksPanel}
            data-animate={current.animate ? "true" : undefined}
            data-role="current"
            edgeEffect="mask"
            edgeMask={EDGE_MASK}
            key={`panel-${current.stamp}`}
            orientation="vertical"
            onContentResize={refreshCardOffsets}
            onViewportResize={refreshCardOffsets}
            ref={currentViewportRef}
            viewportProps={{ tabIndex: current.entries.length === 0 ? -1 : 0 }}
          >
            <TaskCardReorderList
              className="contents"
              ids={orderedEntries.map((entry) => entry.task.id)}
              onReorder={handleReorder}
            >
              <ul className={homeTasksList} data-testid="home-tasks-card-stack">
                {(() => {
                  // Cards arriving together cascade in list order.
                  let newIndex = 0;
                  return orderedEntries.map((entry) => {
                    const key = itemKey(current.stamp, entry.task.id);
                    const style =
                      entry.state === "new"
                        ? ({
                            "--comma-home-tasks-new-index": Math.min(
                              newIndex++,
                              HOME_TASKS_MAX_NEW_STAGGER
                            ),
                          } as CSSProperties)
                        : undefined;
                    return (
                      <HomeTasksItem
                        data-state={entry.state}
                        itemKey={key}
                        key={key}
                        register={registerItem}
                        style={style}
                      >
                        <TaskCardReorderItem id={entry.task.id}>
                          <HomeTaskCard
                            badges={renderTaskBadges?.(entry.task)}
                            onOpen={onOpenTask}
                            task={entry.task}
                          />
                        </TaskCardReorderItem>
                      </HomeTasksItem>
                    );
                  });
                })()}
              </ul>
            </TaskCardReorderList>
          </ScrollArea>
        )}
      </div>
      {hasTasks ? (
        <footer
          className={homeTasksFooter}
          onBlurCapture={(event) => {
            if (!event.currentTarget.contains(event.relatedTarget)) {
              indicatorFocusedRef.current = false;
            }
          }}
          onFocusCapture={() => {
            indicatorFocusedRef.current = true;
          }}
        >
          <StatusIndicator
            aria-label={messages.tasks_filter_status(undefined, { locale })}
            onChange={handleIndicatorChange}
            value={taskStatusToIndicatorId(status)}
          />
        </footer>
      ) : null}
    </section>
  );
}

function itemKey(stamp: number, id: string): string {
  return `${stamp}:${id}`;
}

/** Keep observation attached across task updates and reorder renders. */
function HomeTasksItem({
  children,
  itemKey: key,
  register,
  trackLayout = true,
  ...props
}: {
  children: ReactNode;
  "data-state"?: string;
  itemKey: string;
  register: (key: string, element: HTMLLIElement, trackLayout: boolean) => () => void;
  style?: CSSProperties | undefined;
  trackLayout?: boolean;
}) {
  const ref = useCallback(
    (element: HTMLLIElement | null) =>
      element ? register(key, element, trackLayout) : undefined,
    [key, register, trackLayout]
  );
  return (
    <li {...props} className={homeTasksItem} ref={ref}>
      {children}
    </li>
  );
}
