import { HomeTasks } from "@comma/ui/components/home-tasks";
import { openTaskTarget } from "../tasks/openTaskTarget";
import type { VisibleTaskStatusBucket } from "@comma/i18n";
import { uiClock } from "@comma/ui/clock";
import { useNavigate } from "@tanstack/react-router";
import { memo, useCallback, useEffect, useRef, useState } from "react";
import { useOpenTasksFilter } from "../tasks/taskChips";
import { TaskStepCards } from "../tasks/taskSteps";
import { useTaskBadges } from "../tasks/useTaskBadges";
import { useTaskOrder } from "../tasks/useTaskOrder";
import { useWorkspaceTasks, type TaskViewModel } from "../tasks/useWorkspaceTasks";

/** Ignore auto-follow for a beat after the user picks a status themselves. */
const MANUAL_SELECTION_HOLD_MS = 8_000;
/**
 * Which bucket the rail falls back to when the one it is showing empties.
 * Work in flight outranks an archive: the freshest Task is often the one that
 * just finished, and opening Home on "done" hides the ones still running.
 */
const FOLLOW_PRIORITY: readonly VisibleTaskStatusBucket[] = [
  "in_progress",
  "needs_review",
  "done",
  "cancelled",
];
const EMPTY_TASKS: readonly TaskViewModel[] = [];

type RailTask = TaskViewModel & { statusBucket: VisibleTaskStatusBucket };

/** The rail shows the Tasks of the status switcher's buckets; its source already leaves archived ones out. */
function shownOnRail(task: TaskViewModel): task is RailTask {
  return task.statusBucket !== "archived";
}

/**
 * Keeps the Home Tasks surface stable before Workspace Chat has resolved,
 * without starting the product-inbox projection against a session that may
 * still be mounting or tearing down.
 */
export function HomeTasksRailLoading() {
  return (
    <HomeTasks<TaskViewModel>
      onOpenTask={() => undefined}
      onStatusChange={() => undefined}
      ready={false}
      status="in_progress"
      tasks={EMPTY_TASKS}
    />
  );
}

/**
 * Comma home Tasks rail: the componentized task stack bound to the
 * status-indicator switcher. Follows the same product-inbox projection as the
 * Tasks panel, so tasks created through the Comma Router agent appear here too;
 * when one arrives live, the rail switches to its status bucket so the new
 * card's entrance is visible.
 */
// Memoized: the Home screen that mounts this rail re-renders on every chat
// emit — each composer keystroke included — and re-creates the rail's element.
// The rail's own subscriptions decide when it renders; a keystroke is not one.
export const HomeTasksRail = memo(function HomeTasksRail({
  enabled = true,
}: {
  enabled?: boolean;
} = {}) {
  const navigate = useNavigate();
  const { activeGroupId, activeWorkspaceId, loading, result, taskLoadError, tasks } =
    useWorkspaceTasks({ enabled, stationTasks: true });
  const { orders, setBucketOrder } = useTaskOrder(activeGroupId, tasks);
  // The Tasks board's Loops, label and platform chips, so a card reads the
  // same here.
  const openTasksFilter = useOpenTasksFilter();
  const { renderTaskBadges } = useTaskBadges(activeGroupId, tasks, openTasksFilter);
  const [status, setStatus] = useState<VisibleTaskStatusBucket>("in_progress");
  const manualAtRef = useRef(0);
  /** True while the visible status is the user's own pick, not the rail's. */
  const manualStatusRef = useRef(false);
  const knownIdsRef = useRef<Set<string> | null>(null);
  const knownWorkspaceRef = useRef(activeWorkspaceId);

  const handleStatusChange = useCallback((bucket: VisibleTaskStatusBucket) => {
    manualAtRef.current = uiClock.now();
    manualStatusRef.current = true;
    setStatus(bucket);
  }, []);

  useEffect(() => {
    // Auto-follow reacts to tasks that arrive live, never to a list that was
    // merely (re)loaded — so rebaseline whenever the source resets: loading
    // gaps, workspace switches, and error results whose recovery would
    // otherwise replay the whole list as "new arrivals". The workspace key
    // comes from the result snapshot so it stays consistent with `tasks` even
    // when the projection swaps workspaces before local state catches up.
    const workspaceKey = result?.activeWorkspaceId ?? activeWorkspaceId;
    if (workspaceKey !== knownWorkspaceRef.current) {
      knownWorkspaceRef.current = workspaceKey;
      knownIdsRef.current = null;
      manualStatusRef.current = false;
    }
    if (loading) {
      knownIdsRef.current = null;
      return;
    }
    if (result?.source === "error" || result?.source === "unavailable") {
      knownIdsRef.current = null;
      return;
    }

    const shownTasks = tasks.filter(shownOnRail);
    const ids = new Set(shownTasks.map((task) => task.id));
    const known = knownIdsRef.current;
    knownIdsRef.current = ids;

    let arrived: RailTask | undefined;
    if (known !== null) {
      for (const task of shownTasks) {
        if (known.has(task.id)) continue;
        if (!arrived || task.updatedAt > arrived.updatedAt) arrived = task;
      }
    }
    if (arrived) {
      if (uiClock.now() - manualAtRef.current < MANUAL_SELECTION_HOLD_MS) return;
      manualStatusRef.current = false;
      setStatus(arrived.statusBucket);
      return;
    }

    // Nothing arrived, so the rail is showing a status nobody asked for. A
    // Task leaves its bucket the moment its status moves on — a created Task
    // is `active` and turns into `ready_for_review` minutes later — and the
    // first list a rail ever receives is adopted as a baseline without a
    // follow. Either way the rail would sit on an empty bucket claiming "No
    // tasks" while Tasks exist. Follow the Tasks that are still moving; a
    // status the user picked themselves is theirs to keep.
    if (manualStatusRef.current || shownTasks.length === 0) return;
    if (shownTasks.some((task) => task.statusBucket === status)) return;

    let target = shownTasks[0]!;
    for (const task of shownTasks) {
      const rank = FOLLOW_PRIORITY.indexOf(task.statusBucket);
      const best = FOLLOW_PRIORITY.indexOf(target.statusBucket);
      if (rank < best || (rank === best && task.updatedAt > target.updatedAt)) {
        target = task;
      }
    }
    setStatus(target.statusBucket);
  }, [activeWorkspaceId, loading, result, status, tasks]);

  const openTask = useCallback(
    (task: TaskViewModel) => {
      void navigate(openTaskTarget(task));
    },
    [navigate]
  );

  // Running cards show their Workers' latest steps while Home shows.
  return (
    <TaskStepCards active={enabled}>
      <HomeTasks
        onOpenTask={openTask}
        onStatusChange={handleStatusChange}
        onTaskOrderChange={setBucketOrder}
        ready={!loading && taskLoadError === undefined}
        renderTaskBadges={renderTaskBadges}
        status={status}
        taskOrder={orders}
        tasks={tasks}
      />
    </TaskStepCards>
  );
});
